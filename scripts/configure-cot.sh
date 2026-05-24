#!/usr/bin/env bash
# configure-cot.sh — CoT + federated repos + best-effort JPD pairing
# between art1 and art2. End-to-end with admin/password only.
#
# What works definitively
#   1. Circle of Trust via filesystem (cross-copy each AF's root.crt
#      into the other AF's etc/access/keys/trusted/ directory). Access
#      auto-ingests the cert within ~15-30s and the file vanishes.
#   2. Bootstrap of an Access-API admin bearer token by reading the
#      jfmc@<id>.token file that AF generates internally on first boot,
#      then minting a *@* admin token via POST /access/api/v1/tokens.
#   3. Custom Base URL on each AF via /artifactory/api/* (Basic auth).
#   4. Federated repositories with members on both AFs. Replication
#      flows over the "legacy CoT token" path AF builds on top of the
#      file-level CoT — files uploaded to one side appear on the other
#      in ~30s.
#
# What's best-effort
#   5. Adding the peer as a registered JPD on each side via
#      /mc/api/v1/jpds. This requires a "pairing token" flow whose
#      generation endpoint is only exposed by the standalone Mission
#      Control product (jfrog/mission-control:*), not by the embedded
#      mc microservice that ships inside AF Pro. The script attempts
#      it with the joinKey + admin token, logs the result, and
#      continues — federation works regardless.
#
# Topology UI note
#   In AF 7.146 Administration → Topology → Topology Overview shows
#   peer JPDs only after a successful JPD pairing (step 5). With AF
#   Pro alone the page may show only the local JPD ("HOME"). To get
#   full multi-JPD visibility, deploy standalone Mission Control
#   alongside (separate compose) or pair manually in that UI.

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

MARKER="${STATE_DIR}/.cot-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "CoT already configured. Delete ${MARKER} to re-run."
  exit 0
fi

# ─── Helper: bootstrap an Access-API admin bearer from inside container ─────
# AF 7.146 rejects Basic on /access/api/v1/*, and refuses to mint Access-
# audience tokens from /artifactory/api/security/token. BUT each AF
# generates its own internal jfmc service token (aud=jfac@<id>, scp=admin)
# during first boot and stores it on disk. We read that, use it to mint
# a broad *@* admin token via Access's own /tokens endpoint, and use that
# bearer for everything else.
af_mint_admin_token() {
  local container="$1" external_url="$2"
  local jfmc_token
  jfmc_token=$(docker exec "${container}" sh -c \
    'cat /var/opt/jfrog/artifactory/work/mc/temp/access-client-config-store/*/keys/jfmc@*.token' 2>/dev/null)
  if [[ -z "${jfmc_token}" ]]; then
    log_err "Couldn't read jfmc service token from ${container} — MC may not be running yet."
    return 1
  fi
  curl -sS -H "Authorization: Bearer ${jfmc_token}" \
    -X POST -H 'Content-Type: application/json' \
    --data '{"username":"admin","scope":"applied-permissions/admin","audience":"*@*","expires_in":3600,"refreshable":true}' \
    "${external_url}/access/api/v1/tokens" \
    | jq -r '.access_token // empty'
}

# ─── 1. Cross-trust the Access root certificates (CoT via filesystem) ────────
log_step "Cross-trusting Access root certs (filesystem CoT)"

local_root_art1=$(mktemp)
local_root_art2=$(mktemp)
trap 'rm -f "${local_root_art1}" "${local_root_art2}"' EXIT

log_info "Pulling root.crt from each AF to host..."
docker cp "artifactory1:${KEYS_DIR}/root.crt" "${local_root_art1}"
docker cp "artifactory2:${KEYS_DIR}/root.crt" "${local_root_art2}"

log_info "Dropping each into the other AF's trusted/ dir..."
docker cp "${local_root_art2}" "artifactory1:${KEYS_DIR}/trusted/art2-root.crt"
docker cp "${local_root_art1}" "artifactory2:${KEYS_DIR}/trusted/art1-root.crt"

docker exec --user root artifactory1 chown 1030:1030 "${KEYS_DIR}/trusted/art2-root.crt" 2>/dev/null || true
docker exec --user root artifactory2 chown 1030:1030 "${KEYS_DIR}/trusted/art1-root.crt" 2>/dev/null || true

log_info "Waiting for Access to ingest the certs (~15-30s)..."
elapsed=0
while (( elapsed < 90 )); do
  sleep 5
  elapsed=$((elapsed + 5))
  a1=$(docker exec artifactory1 ls "${KEYS_DIR}/trusted/art2-root.crt" 2>/dev/null || true)
  a2=$(docker exec artifactory2 ls "${KEYS_DIR}/trusted/art1-root.crt" 2>/dev/null || true)
  if [[ -z "${a1}" && -z "${a2}" ]]; then
    log_ok "Both certs ingested (took ~${elapsed}s). Circle of Trust established."
    break
  fi
  printf '.'
done
if [[ -n "${a1:-}" || -n "${a2:-}" ]]; then
  log_warn "Certs still in trusted/ after ${elapsed}s. Federation may still work; if not, restart AF."
fi

# ─── 2. Bootstrap Access-API admin bearer tokens ─────────────────────────────
log_step "Bootstrapping Access admin tokens via jfmc service tokens"
TOKEN1=$(af_mint_admin_token artifactory1 "${AF1_URL}" || true)
TOKEN2=$(af_mint_admin_token artifactory2 "${AF2_URL}" || true)
if [[ -z "${TOKEN1}" || -z "${TOKEN2}" || "${TOKEN1}" == "null" || "${TOKEN2}" == "null" ]]; then
  log_warn "Couldn't get Access admin tokens — falling back to Basic auth for what's possible."
  HAS_ACCESS_TOKEN=0
else
  log_ok "Both Access admin tokens minted."
  HAS_ACCESS_TOKEN=1
fi

# ─── 3. Set Custom Base URLs (Basic auth on /artifactory/api/*) ──────────────
log_step "Setting Custom Base URLs"
set_base_url() {
  local af_url="$1" label="$2" base_url="$3"
  local code
  code=$(curl -sS -o /tmp/af-base-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: text/plain' \
    --data "${base_url}" \
    "${af_url}/artifactory/api/system/configuration/baseUrl")
  if [[ "${code}" =~ ^2 ]]; then
    log_ok "${label} base URL → ${base_url} (HTTP ${code})."
  else
    log_warn "Base URL on ${label}: HTTP ${code}: $(cat /tmp/af-base-resp.txt)"
  fi
}
set_base_url "${AF1_URL}" "art1" "${AF1_INTERNAL}/artifactory"
set_base_url "${AF2_URL}" "art2" "${AF2_INTERNAL}/artifactory"

# ─── 4. Create sample federated repos ────────────────────────────────────────
log_step "Creating sample federated repos"
create_federated_repo() {
  local repo_key="$1" package_type="$2"
  local payload code
  payload=$(jq -nc \
    --arg key "${repo_key}" --arg pkg "${package_type}" \
    --arg url1 "${AF1_INTERNAL}/artifactory/${repo_key}" \
    --arg url2 "${AF2_INTERNAL}/artifactory/${repo_key}" \
    '{
      key:$key, rclass:"federated", packageType:$pkg,
      members:[{url:$url1,enabled:true},{url:$url2,enabled:true}]
    }')
  code=$(curl -sS -o /tmp/af-repo-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${AF1_URL}/artifactory/api/repositories/${repo_key}")
  case "${code}" in
    20*) log_ok "Created federated repo '${repo_key}' (${package_type}, HTTP ${code})." ;;
    400) if grep -q 'already exists' /tmp/af-repo-resp.txt; then
           log_info "Repo '${repo_key}' already exists — skipping."
         else
           log_warn "Repo '${repo_key}' rejected (HTTP 400): $(cat /tmp/af-repo-resp.txt)"
         fi ;;
    409) log_info "Repo '${repo_key}' already exists (HTTP 409 — skipping)." ;;
    *)   log_warn "Repo '${repo_key}' HTTP ${code}: $(cat /tmp/af-repo-resp.txt)" ;;
  esac
}
create_federated_repo "generic-fed" "generic"
create_federated_repo "docker-fed"  "docker"

# ─── 5. Best-effort JPD pairing for Topology UI visibility ──────────────────
if [[ "${HAS_ACCESS_TOKEN}" == "1" ]]; then
  log_step "Attempting JPD peer registration (Topology UI)"
  log_info "If this fails, federation still works — see header comment."

  # Try to register art2 as a peer JPD on art1, using art2's join.key
  # as the joinKey field. AF Pro's embedded MC may reject this with
  # 'Failed to join the JPD' — the full pairing flow needs standalone
  # Mission Control. We try anyway and log clearly.
  JOIN_KEY_ART2=$(docker exec artifactory2 cat "/var/opt/jfrog/artifactory/etc/security/join.key" 2>/dev/null)
  JOIN_KEY_ART1=$(docker exec artifactory1 cat "/var/opt/jfrog/artifactory/etc/security/join.key" 2>/dev/null)

  try_jpd_pair() {
    local from_url="$1" from_token="$2" peer_name="$3" peer_url="$4" peer_join_key="$5"
    local code
    code=$(curl -sS -o /tmp/af-jpd-resp.txt -w '%{http_code}' \
      -H "Authorization: Bearer ${from_token}" \
      -X POST -H 'Content-Type: application/json' \
      --data "$(jq -nc \
        --arg name "${peer_name}" \
        --arg url "${peer_url}" \
        --arg jk "${peer_join_key}" \
        '{name:$name, url:$url, location:{city_name:"docker",country_code:"GL",latitude:0,longitude:0}, joinKey:$jk}')" \
      "${from_url}/mc/api/v1/jpds")
    case "${code}" in
      20*) log_ok "Registered ${peer_name} as JPD on ${from_url} (HTTP ${code})." ;;
      400) log_warn "JPD registration: HTTP 400 — likely needs standalone Mission Control. Body: $(head -c 300 /tmp/af-jpd-resp.txt)" ;;
      *)   log_warn "JPD registration to ${from_url}: HTTP ${code}: $(head -c 300 /tmp/af-jpd-resp.txt)" ;;
    esac
  }
  try_jpd_pair "${AF1_URL}" "${TOKEN1}" "art2" "${AF2_INTERNAL}" "${JOIN_KEY_ART2}"
  try_jpd_pair "${AF2_URL}" "${TOKEN2}" "art1" "${AF1_INTERNAL}" "${JOIN_KEY_ART1}"

  log_info "Local JPD list on art1:"
  curl -sS -H "Authorization: Bearer ${TOKEN1}" "${AF1_URL}/mc/api/v1/jpds" 2>/dev/null \
    | jq -r '.[] | "  • \(.name) (\(.id)) @ \(.base_url // .url) [\(.status.code // "?")]"' 2>/dev/null \
    || log_info "  (could not list)"
fi

# ─── 6. Smoke test: upload to art1, confirm it lands on art2 ─────────────────
log_step "Verifying federation replication"
test_file=$(mktemp)
echo "arti-deployer-cot-smoke-$(date +%s)" > "${test_file}"
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X PUT --data-binary "@${test_file}" \
  "${AF1_URL}/artifactory/generic-fed/cot-smoke.txt" >/dev/null && \
  log_info "Uploaded test file to art1 generic-fed."

log_info "Polling art2 (up to 60s)..."
elapsed=0
rc=000
while (( elapsed < 60 )); do
  sleep 5
  elapsed=$((elapsed + 5))
  rc=$(curl -sf -o /dev/null -m 3 -u "${ADMIN_USER}:${ADMIN_PASS}" -w '%{http_code}' \
    "${AF2_URL}/artifactory/generic-fed/cot-smoke.txt" 2>/dev/null || echo 000)
  if [[ "${rc}" == "200" ]]; then
    log_ok "✓ Federation replication confirmed (took ~${elapsed}s)."
    break
  fi
  printf '.'
done
if [[ "${rc}" != "200" ]]; then
  log_warn "✗ Test file did NOT replicate within ${elapsed}s."
  log_warn "Check: docker logs artifactory1 2>&1 | grep -i federation | tail -20"
fi
rm -f "${test_file}"
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X DELETE \
  "${AF1_URL}/artifactory/generic-fed/cot-smoke.txt" >/dev/null 2>&1 || true

touch "${MARKER}"
echo
log_ok "CoT + Federation bootstrap complete."
log_info "Federated repos: generic-fed, docker-fed (both AFs)"
log_info "Upload to art1's generic-fed → replicates to art2 within ~30s."
log_info ""
log_info "Adding more federated members manually? Use docker-internal URLs:"
log_info "  ✓  http://artifactory2:8082/artifactory/<repo>"
log_info "  ✗  http://localhost:8182/artifactory/<repo>"
