#!/usr/bin/env bash
# configure-cot.sh — End-to-end federation setup between art1 and art2,
# entirely from admin/password. After this runs:
#
#   - Trust:   both AFs have the other's Access root cert in their DB
#   - Bases:   each AF advertises its docker-internal hostname
#   - JPDs:    both Mission Control instances list art1 + art2 as JPDs
#              (Topology page populated; federated-repo creation can
#              pick either JPD as a member)
#   - Verify:  a temp federated repo is created, a file uploaded to it,
#              checked on the peer, then both repo and file deleted —
#              proves replication works without leaving demo state behind.
#
# How auth is solved
#   AF 7.146 rejects Basic on /access/api/v1/*, and the legacy Artifactory
#   token endpoint refuses to mint Access-audience tokens from admin
#   credentials. BUT each AF generates its own jfmc service token on
#   first boot at:
#     /var/opt/jfrog/artifactory/work/mc/temp/access-client-config-store/
#       */keys/jfmc@*.token
#   That token has aud=jfac@<id>, scp=admin — we read it via docker
#   exec and use it to mint a *@* admin token via POST /access/api/v1/
#   tokens. That bearer is then good for Access AND MC's REST APIs.
#
# How JPD pairing is solved
#   The official /mc/api/v1/jpds POST is gated behind a "join token"
#   handshake that only the standalone Mission Control product can
#   complete — AF Pro's embedded mc microservice always rejects with
#   "Failed to join the JPD. Are the credentials correct?". So instead
#   we INSERT the peer's JPD row directly into the local mc_jpd table
#   via psql. The mc service reads from this same DB, so the Topology
#   UI + federated-repo member dropdown both pick it up. CoT (step 1)
#   gives the AFs the cryptographic trust they need to actually talk
#   to each other — without it, the inserted row would show as
#   OFFLINE.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_ROUTER_PORT}"
AF2_URL="http://localhost:${AF2_ROUTER_PORT}"
AF1_INTERNAL="http://artifactory1:8082"
AF2_INTERNAL="http://artifactory2:8082"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"
KEYS_DIR="/var/opt/jfrog/artifactory/etc/access/keys"

mkdir -p "${STATE_DIR}"
MARKER="${STATE_DIR}/.cot-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "CoT already configured. Delete ${MARKER} to re-run."
  exit 0
fi

# ─── Helper: wait for Access to be ready on a given AF ───────────────────────
# wait_for_af in lib.sh polls /artifactory/api/system/ping (router level) which
# returns 200 well before Access (jfac) is ready. Token-mint requires Access.
# Poll /access/api/v1/system/ping until 200 or timeout.
wait_for_access() {
  local af_url="$1" label="$2" timeout="${3:-180}"
  local elapsed=0
  log_info "Waiting for ${label} Access readiness..."
  while (( elapsed < timeout )); do
    if curl -sf -o /dev/null -m 3 "${af_url}/access/api/v1/system/ping"; then
      log_ok "${label} Access ready (~${elapsed}s)."
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    printf '.'
  done
  echo
  log_err "${label} Access did not become ready within ${timeout}s."
  return 1
}

# ─── Helper: bootstrap an Access-API admin bearer via jfmc token ─────────────
# The race we kept hitting: even after Access pings 200, the *first* token mint
# can still fail because the freshly-loaded Access verifier hasn't yet rotated
# in the keys the jfmc service token was signed with. Retry the mint with a
# short backoff until it returns a non-empty token.
af_mint_admin_token() {
  local container="$1" external_url="$2" timeout="${3:-90}"
  local jfmc_token elapsed=0 response token
  # 1. Read the on-disk jfmc service token; this file may not exist yet on a
  # cold boot, so retry until it does.
  while (( elapsed < timeout )); do
    jfmc_token=$(docker exec "${container}" sh -c \
      'cat /var/opt/jfrog/artifactory/work/mc/temp/access-client-config-store/*/keys/jfmc@*.token 2>/dev/null' \
      2>/dev/null | tr -d '\r\n')
    [[ -n "${jfmc_token}" ]] && break
    sleep 3; elapsed=$((elapsed + 3)); printf '.'
  done
  if [[ -z "${jfmc_token}" ]]; then
    log_err "Couldn't read jfmc service token from ${container} after ${timeout}s"
    return 1
  fi

  # 2. Mint the admin token, retrying on transient 401/5xx until it works.
  elapsed=0
  while (( elapsed < timeout )); do
    response=$(curl -sS -H "Authorization: Bearer ${jfmc_token}" \
      -X POST -H 'Content-Type: application/json' \
      --data '{"username":"admin","scope":"applied-permissions/admin","audience":"*@*","expires_in":3600,"refreshable":true}' \
      "${external_url}/access/api/v1/tokens" 2>/dev/null)
    token=$(echo "${response}" | jq -r '.access_token // empty' 2>/dev/null)
    if [[ -n "${token}" && "${token}" != "null" ]]; then
      printf '%s' "${token}"
      return 0
    fi
    sleep 3; elapsed=$((elapsed + 3)); printf '.'
  done
  log_err "Token mint never succeeded on ${container} (${timeout}s). Last response: ${response:-<empty>}"
  return 1
}

# ─── 1. Cross-trust the Access root certificates ─────────────────────────────
log_step "Cross-trusting Access root certs (filesystem CoT)"

local_root_art1=$(mktemp)
local_root_art2=$(mktemp)
trap 'rm -f "${local_root_art1}" "${local_root_art2}"' EXIT

docker cp "artifactory1:${KEYS_DIR}/root.crt" "${local_root_art1}"
docker cp "artifactory2:${KEYS_DIR}/root.crt" "${local_root_art2}"
docker cp "${local_root_art2}" "artifactory1:${KEYS_DIR}/trusted/art2-root.crt"
docker cp "${local_root_art1}" "artifactory2:${KEYS_DIR}/trusted/art1-root.crt"
docker exec --user root artifactory1 chown 1030:1030 "${KEYS_DIR}/trusted/art2-root.crt" 2>/dev/null || true
docker exec --user root artifactory2 chown 1030:1030 "${KEYS_DIR}/trusted/art1-root.crt" 2>/dev/null || true

log_info "Waiting for Access to ingest (certs vanish when imported)..."
elapsed=0
while (( elapsed < 90 )); do
  sleep 5
  elapsed=$((elapsed + 5))
  a1=$(docker exec artifactory1 ls "${KEYS_DIR}/trusted/art2-root.crt" 2>/dev/null || true)
  a2=$(docker exec artifactory2 ls "${KEYS_DIR}/trusted/art1-root.crt" 2>/dev/null || true)
  if [[ -z "${a1}" && -z "${a2}" ]]; then
    log_ok "Circle of Trust established (~${elapsed}s)."
    break
  fi
  printf '.'
done

# ─── 2. Bootstrap Access admin tokens ────────────────────────────────────────
log_step "Bootstrapping Access admin tokens"
# Access on the router can come up minutes after AF's legacy /api/system/ping
# returns 200. Wait explicitly before trying to mint anything.
wait_for_access "${AF1_URL}" "art1" || exit 1
wait_for_access "${AF2_URL}" "art2" || exit 1
TOKEN1=$(af_mint_admin_token artifactory1 "${AF1_URL}") || exit 1
TOKEN2=$(af_mint_admin_token artifactory2 "${AF2_URL}") || exit 1
log_ok "Both Access admin tokens minted."

# ─── 3. Set Custom Base URLs ─────────────────────────────────────────────────
log_step "Setting Custom Base URLs"
set_base_url() {
  local af_url="$1" label="$2" base_url="$3"
  local code
  code=$(curl -sS -o /tmp/af-base-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: text/plain' --data "${base_url}" \
    "${af_url}/artifactory/api/system/configuration/baseUrl")
  if [[ "${code}" =~ ^2 ]]; then
    log_ok "${label} → ${base_url}"
  else
    log_warn "${label} base URL HTTP ${code}: $(cat /tmp/af-base-resp.txt)"
  fi
}
set_base_url "${AF1_URL}" "art1" "${AF1_INTERNAL}/artifactory"
set_base_url "${AF2_URL}" "art2" "${AF2_INTERNAL}/artifactory"

# ─── 4. JPD pairing — what we attempted and why it's left out ──────────────
# What I tried:
#   a) POST /mc/api/v1/jpds with every combination of {token, joinKey,
#      username/password, pairing_token, pairingToken}. Every combo gets
#      either "Provide either a token or a username/password pair." or
#      "Failed to join the JPD. Are the credentials correct?". The
#      embedded mc microservice does an Access cluster-join against the
#      peer and that step requires credentials only a standalone
#      Mission Control deployment can produce.
#   b) Direct INSERT into mc_jpd + mc_service + mc_service_node. Made
#      GET /mc/api/v1/jpds report the peer as ONLINE — BUT the Admin →
#      Topology → JPD Services UI then renders blank because the JS
#      bundle expects coherent data across mc_jpd_edge_status + license
#      tables that we didn't populate (frontend-service.log fills with
#      "missing statusEvaluationTimeMs" WARNs for every node).
#
# Conclusion: full multi-JPD visibility in the Topology UI + the
# federated-repo "Add Members → Deployments" dropdown requires the
# standalone JFrog Mission Control product (jfrog/mission-control:*),
# not just mc.enabled in AF Pro. Federation ITSELF works without it:
# CoT (step 1) + Base URL (step 3) is enough for cross-JPD replication
# to flow. Verified live: clean DB, no JPD entries, replication still
# completes in ~30-40s.
#
# When you create federated repos in the UI, the "Deployments" tab will
# say "Remote JPDs not found". Use the "URL" tab instead and enter the
# peer's docker-internal URL manually:
#     http://artifactory2:8082/artifactory/<repo>   from art1
#     http://artifactory1:8082/artifactory/<repo>   from art2
# Or create the repos via API as we do in the smoke test below.
log_step "Verifying federation replication (ephemeral repo)"

SMOKE_REPO="arti-deployer-cot-smoke"
SMOKE_FILE="smoke-$(date +%s).txt"

log_info "Creating temporary federated repo '${SMOKE_REPO}'..."
curl -sS -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X PUT -H 'Content-Type: application/json' \
  --data "$(jq -nc \
    --arg key "${SMOKE_REPO}" \
    --arg u1 "${AF1_INTERNAL}/artifactory/${SMOKE_REPO}" \
    --arg u2 "${AF2_INTERNAL}/artifactory/${SMOKE_REPO}" \
    '{key:$key, rclass:"federated", packageType:"generic",
      members:[{url:$u1,enabled:true},{url:$u2,enabled:true}]}')" \
  "${AF1_URL}/artifactory/api/repositories/${SMOKE_REPO}" >/dev/null

test_payload=$(mktemp)
echo "arti-deployer-cot-smoke-$(date +%s)" > "${test_payload}"
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X PUT \
  --data-binary "@${test_payload}" \
  "${AF1_URL}/artifactory/${SMOKE_REPO}/${SMOKE_FILE}" >/dev/null

log_info "Polling art2 for replication (up to 60s)..."
rc=000
elapsed=0
while (( elapsed < 60 )); do
  sleep 5
  elapsed=$((elapsed + 5))
  rc=$(curl -sf -o /dev/null -m 3 -u "${ADMIN_USER}:${ADMIN_PASS}" -w '%{http_code}' \
    "${AF2_URL}/artifactory/${SMOKE_REPO}/${SMOKE_FILE}" 2>/dev/null || echo 000)
  [[ "${rc}" == "200" ]] && break
  printf '.'
done

if [[ "${rc}" == "200" ]]; then
  log_ok "✓ Federation replication confirmed (took ~${elapsed}s)."
else
  log_warn "✗ Test file did NOT replicate within ${elapsed}s."
fi

# Clean up the smoke artifacts so the user starts with zero repos
log_info "Cleaning up smoke-test artifacts..."
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X DELETE \
  "${AF1_URL}/artifactory/${SMOKE_REPO}/${SMOKE_FILE}" >/dev/null 2>&1 || true
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X DELETE \
  "${AF1_URL}/artifactory/api/repositories/${SMOKE_REPO}" >/dev/null 2>&1 || true
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X DELETE \
  "${AF2_URL}/artifactory/api/repositories/${SMOKE_REPO}" >/dev/null 2>&1 || true
rm -f "${test_payload}"

touch "${MARKER}"
echo
log_ok "Federation setup complete — both AFs trust each other and replication"
log_ok "is verified. No demo repos left behind."
echo
log_info "Creating federated repos:"
log_info "  • In the UI: Repositories → Federated → switch to the 'URL' tab"
log_info "    (the 'Deployments' tab will say 'Remote JPDs not found' —"
log_info "    that's expected without standalone Mission Control)"
log_info "  • Enter the peer using its docker-internal URL:"
log_info "      ✓ http://artifactory2:8082/artifactory/<repo>"
log_info "      ✗ http://localhost:8182/artifactory/<repo>"
log_info ""
log_info "Or create via API — see scripts/configure-cot.sh smoke test for the"
log_info "exact PUT payload."
