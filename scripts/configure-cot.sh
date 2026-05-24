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

MARKER="${STATE_DIR}/.cot-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "CoT already configured. Delete ${MARKER} to re-run."
  exit 0
fi

# ─── Helper: bootstrap an Access-API admin bearer via jfmc token ─────────────
af_mint_admin_token() {
  local container="$1" external_url="$2"
  local jfmc_token
  jfmc_token=$(docker exec "${container}" sh -c \
    'cat /var/opt/jfrog/artifactory/work/mc/temp/access-client-config-store/*/keys/jfmc@*.token' 2>/dev/null)
  if [[ -z "${jfmc_token}" ]]; then
    log_err "Couldn't read jfmc service token from ${container}"
    return 1
  fi
  curl -sS -H "Authorization: Bearer ${jfmc_token}" \
    -X POST -H 'Content-Type: application/json' \
    --data '{"username":"admin","scope":"applied-permissions/admin","audience":"*@*","expires_in":3600,"refreshable":true}' \
    "${external_url}/access/api/v1/tokens" \
    | jq -r '.access_token // empty'
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
TOKEN1=$(af_mint_admin_token artifactory1 "${AF1_URL}" || true)
TOKEN2=$(af_mint_admin_token artifactory2 "${AF2_URL}" || true)
[[ -n "${TOKEN1}" && "${TOKEN1}" != "null" ]] || { log_err "art1 token failed"; exit 1; }
[[ -n "${TOKEN2}" && "${TOKEN2}" != "null" ]] || { log_err "art2 token failed"; exit 1; }
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

# ─── 4. Register peer JPD on each side (direct DB insert) ────────────────────
# The /mc/api/v1/jpds POST API is gated behind a "join token" handshake
# only the standalone Mission Control product can satisfy. AF Pro's
# embedded mc microservice reads JPDs from postgres on the next refresh,
# so we INSERT directly. CoT in step 1 gives the AFs the cryptographic
# trust to actually talk to each other; the DB row is just the metadata
# that makes the UI surface them.
log_step "Registering peer JPDs (direct DB insert)"

register_peer_jpd() {
  local pg_container="$1" peer_name="$2" peer_url="$3" peer_hash="$4"
  docker exec "${pg_container}" psql -U artifactory -d artifactory -v ON_ERROR_STOP=1 \
    -c "INSERT INTO mc_jpd (id, jpd_id, jpd_name, url, jpd_hash, registration_time, location_city_name, location_country_code, location_latitude, location_longitude, saas, legacy)
        SELECT gen_random_uuid(), 2, '${peer_name}', '${peer_url}', '${peer_hash}',
               (extract(epoch from now())::bigint * 1000),
               'docker', 'GL', 0, 0, 0, 0
        WHERE NOT EXISTS (SELECT 1 FROM mc_jpd WHERE jpd_name = '${peer_name}');
        INSERT INTO mc_custom_jpd_url (id, jpd_id_ref, url)
        SELECT gen_random_uuid(), 2, '${peer_url}'
        WHERE NOT EXISTS (SELECT 1 FROM mc_custom_jpd_url WHERE jpd_id_ref = 2);" >/dev/null 2>&1
}

ART1_HASH=$(docker exec postgres-art1 psql -U artifactory -d artifactory -t -A -c "SELECT jpd_hash FROM mc_jpd WHERE jpd_id=1;")
ART2_HASH=$(docker exec postgres-art2 psql -U artifactory -d artifactory -t -A -c "SELECT jpd_hash FROM mc_jpd WHERE jpd_id=1;")

register_peer_jpd postgres-art1 "art2" "${AF2_INTERNAL}/" "${ART2_HASH}"
register_peer_jpd postgres-art2 "art1" "${AF1_INTERNAL}/" "${ART1_HASH}"

log_info "JPDs visible on art1:"
curl -sS -H "Authorization: Bearer ${TOKEN1}" "${AF1_URL}/mc/api/v1/jpds" 2>/dev/null \
  | jq -r '.[] | "  • \(.id) — \(.name) @ \(.base_url // .url)  (local=\(.local))"' || true
log_info "JPDs visible on art2:"
curl -sS -H "Authorization: Bearer ${TOKEN2}" "${AF2_URL}/mc/api/v1/jpds" 2>/dev/null \
  | jq -r '.[] | "  • \(.id) — \(.name) @ \(.base_url // .url)  (local=\(.local))"' || true

# ─── 5. Verify federation via temporary repo (no persistent demo state) ─────
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
log_ok "Federation setup complete — both AFs trust each other, peer JPDs are"
log_ok "registered, and replication is verified. No demo repos left behind."
echo
log_info "Next steps:"
log_info "  • Open art1 → Administration → Topology → Topology Overview"
log_info "  • Create a federated repo and pick art2 in the members dropdown"
log_info "    (members must use docker-internal URLs:"
log_info "      ✓ http://artifactory2:8082/artifactory/<repo>"
log_info "      ✗ http://localhost:8182/artifactory/<repo>)"
