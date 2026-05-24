#!/usr/bin/env bash
# configure-cot.sh — End-to-end Circle of Trust + Access Federation between
# art1 and art2, plus sample federated repos as smoke tests.
#
# Steps
#   1. Get admin bearer tokens on both AFs (Access /api/v1/* needs Bearer
#      in 7.100+; basic auth no longer works on those endpoints).
#   2. Set each AF's Custom Base URL — federation refuses to start without
#      one (UI says: "Federated repository requires a Custom Base URL").
#   3. Pull each AF's Access root certificate.
#   4. Cross-trust them via POST /access/api/v1/system/trusted_keys.
#   5. Pair the JPDs (token-based bind). Tries the modern endpoint with
#      a fallback to the older topology API.
#   6. Create sample federated repos (`generic-fed`, `docker-fed`) on art1
#      with both AFs as members using the correct docker-internal URLs.
#
# URL gotcha
#   When the UI asks for a federation member URL, you MUST use the docker
#   hostname (http://artifactory2:8082/artifactory/REPO), NOT
#   http://localhost:8182/...  AF1 validates the URL by HTTP-connecting
#   to it from inside its own container, where "localhost" is AF1 itself,
#   not the host machine.

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

MARKER="${STATE_DIR}/.cot-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "CoT already configured. Delete ${MARKER} to re-run."
  exit 0
fi

fail_soft() {
  log_warn "$1"
  log_warn "Continuing — manual UI step may be needed; see docs/cot-federation.md."
}

# ─── 1. Bearer tokens ────────────────────────────────────────────────────────
log_step "Acquiring admin bearer tokens"
TOKEN1=$(af_admin_token "${AF1_URL}")
TOKEN2=$(af_admin_token "${AF2_URL}")
if [[ -z "${TOKEN1}" || "${TOKEN1}" == "null" ]]; then
  log_err "Could not get bearer token from art1 — check AF_ADMIN_PASSWORD in .env."
  exit 1
fi
if [[ -z "${TOKEN2}" || "${TOKEN2}" == "null" ]]; then
  log_err "Could not get bearer token from art2."
  exit 1
fi
HDR1=(-H "Authorization: Bearer ${TOKEN1}")
HDR2=(-H "Authorization: Bearer ${TOKEN2}")
log_ok "Bearer tokens acquired for both instances."

# ─── 2. Custom Base URLs ─────────────────────────────────────────────────────
log_step "Setting Custom Base URLs"
set_base_url() {
  local af_url="$1" label="$2" base_url="$3" token="$4"
  log_info "${label}: ${base_url}"
  local code
  code=$(curl -sS -o /tmp/af-base-resp.txt -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -X PUT -H 'Content-Type: text/plain' \
    --data "${base_url}" \
    "${af_url}/artifactory/api/system/configuration/baseUrl")
  if [[ "${code}" =~ ^2 ]]; then
    log_ok "Base URL set on ${label} (HTTP ${code})."
  else
    fail_soft "Base URL PUT on ${label} returned ${code}: $(cat /tmp/af-base-resp.txt)"
  fi
}
set_base_url "${AF1_URL}" "art1" "${AF1_INTERNAL}/artifactory" "${TOKEN1}"
set_base_url "${AF2_URL}" "art2" "${AF2_INTERNAL}/artifactory" "${TOKEN2}"

# ─── 3. Fetch each instance's Access root certificate ────────────────────────
log_step "Fetching Access root certificates"
CERT1=$(curl -sS "${HDR1[@]}" "${AF1_URL}/access/api/v1/system/root_certificate") || \
  fail_soft "Couldn't fetch art1 root cert."
CERT2=$(curl -sS "${HDR2[@]}" "${AF2_URL}/access/api/v1/system/root_certificate") || \
  fail_soft "Couldn't fetch art2 root cert."
mkdir -p "${STATE_DIR}"
echo "${CERT1}" > "${STATE_DIR}/art1-root.pem"
echo "${CERT2}" > "${STATE_DIR}/art2-root.pem"
log_ok "Root certs saved under ${STATE_DIR}/."

# ─── 4. Cross-trust (Circle of Trust) ────────────────────────────────────────
log_step "Cross-trusting the root certificates"
trust_cert() {
  local target_url="$1" target_label="$2" cert_pem="$3" kid="$4" token="$5"
  log_info "Trusting ${kid} on ${target_label}"
  local payload code
  payload=$(jq -nc --arg k "${cert_pem}" --arg id "${kid}" '{key:$k, kid:$id}')
  code=$(curl -sS -o /tmp/af-trust-resp.txt -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -X POST -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${target_url}/access/api/v1/system/trusted_keys")
  case "${code}" in
    20*) log_ok "${target_label} trusts ${kid} (HTTP ${code})." ;;
    409) log_info "${target_label} already trusts ${kid} (HTTP 409 — duplicate)." ;;
    *)   fail_soft "trusted_keys POST to ${target_label} returned ${code}: $(cat /tmp/af-trust-resp.txt)" ;;
  esac
}
trust_cert "${AF1_URL}" "art1" "${CERT2}" "art2-root" "${TOKEN1}"
trust_cert "${AF2_URL}" "art2" "${CERT1}" "art1-root" "${TOKEN2}"

# ─── 5. JPD pairing (token-based bind) ───────────────────────────────────────
# Modern AF: a pairing token is generated on the source, then consumed on
# the target. Endpoint shape has shifted across versions — try the current
# one first, fall back to the older topology endpoint, and log clearly if
# both fail so the user can finish in the UI.
log_step "Pairing the JPDs (Access Federation)"

generate_pair_token() {
  local af_url="$1" token="$2"
  local body code
  body=$(curl -sS -o /tmp/af-pair-resp.txt -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -X POST -H 'Content-Type: application/json' \
    --data '{"scope":"applied-permissions/admin","expires_in":3600}' \
    "${af_url}/access/api/v1/system/jpd/pair")
  echo "${body}"
}

PAIR_HTTP=$(generate_pair_token "${AF1_URL}" "${TOKEN1}")
if [[ "${PAIR_HTTP}" =~ ^2 ]]; then
  PAIRING_TOKEN=$(jq -r '.access_token // .token // .pairing_token // empty' /tmp/af-pair-resp.txt)
  if [[ -n "${PAIRING_TOKEN}" && "${PAIRING_TOKEN}" != "null" ]]; then
    log_ok "Pairing token generated on art1."
    BIND_HTTP=$(curl -sS -o /tmp/af-bind-resp.txt -w '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN2}" \
      -X POST -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg token "${PAIRING_TOKEN}" --arg url "${AF1_INTERNAL}" \
        '{token: $token, base_url: $url}')" \
      "${AF2_URL}/access/api/v1/system/jpd/bind")
    if [[ "${BIND_HTTP}" =~ ^2 ]]; then
      log_ok "art2 bound to art1 (HTTP ${BIND_HTTP})."
    else
      fail_soft "Bind on art2 returned HTTP ${BIND_HTTP}: $(cat /tmp/af-bind-resp.txt)"
    fi
  else
    fail_soft "pair endpoint returned 2xx but no token in body — see /tmp/af-pair-resp.txt"
  fi
else
  log_warn "JPD pair endpoint /access/api/v1/system/jpd/pair returned HTTP ${PAIR_HTTP}"
  log_warn "Falling back to older topology federation_target endpoint..."
  FALLBACK_HTTP=$(curl -sS -o /tmp/af-fed-resp.txt -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN1}" \
    -X POST -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg url "${AF2_INTERNAL}" \
      '{target_url:$url, propagate_groups:true, propagate_users:true, propagate_permissions:true}')" \
    "${AF1_URL}/access/api/v1/topology/federation_target")
  case "${FALLBACK_HTTP}" in
    20*) log_ok "Topology federation_target registered on art1 (HTTP ${FALLBACK_HTTP})." ;;
    *)   fail_soft "Both pair endpoints failed. Configure manually: UI → Administration → User Management → Access Federation." ;;
  esac
fi

# Verify (best-effort — different versions expose different endpoints)
log_step "Verifying JPD topology"
if curl -sS "${HDR1[@]}" "${AF1_URL}/access/api/v1/system/jpd" >/tmp/af-jpd.json 2>&1; then
  log_info "art1 JPD list:"
  jq -r '.[] | "  - \(.name // .service_id // "?") @ \(.base_url // "?")"' </tmp/af-jpd.json 2>/dev/null || \
    cat /tmp/af-jpd.json | head -20
fi

# ─── 6. Sample federated repos ───────────────────────────────────────────────
# Both members use the docker-internal hostname so AF can reach the other
# side over the bridge net. localhost:81xx WILL NOT WORK from inside the
# AF container — that's the most common federation pitfall.
log_step "Creating sample federated repos"

create_federated_repo() {
  local repo_key="$1" package_type="$2"
  local payload code
  payload=$(jq -nc \
    --arg key "${repo_key}" \
    --arg pkg "${package_type}" \
    --arg url1 "${AF1_INTERNAL}/artifactory/${repo_key}" \
    --arg url2 "${AF2_INTERNAL}/artifactory/${repo_key}" \
    '{
      key: $key,
      rclass: "federated",
      packageType: $pkg,
      members: [
        {url: $url1, enabled: true},
        {url: $url2, enabled: true}
      ]
    }')
  code=$(curl -sS -o /tmp/af-repo-resp.txt -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN1}" \
    -X PUT -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${AF1_URL}/artifactory/api/repositories/${repo_key}")
  case "${code}" in
    20*) log_ok "Created federated repo '${repo_key}' (${package_type}, HTTP ${code})." ;;
    400) log_warn "Repo '${repo_key}' rejected (HTTP 400). Body: $(cat /tmp/af-repo-resp.txt)" ;;
    409) log_info "Repo '${repo_key}' already exists (HTTP 409 — skipping)." ;;
    *)   fail_soft "Repo '${repo_key}' create returned HTTP ${code}: $(cat /tmp/af-repo-resp.txt)" ;;
  esac
}

create_federated_repo "generic-fed" "generic"
create_federated_repo "docker-fed"  "docker"

touch "${MARKER}"
echo
log_ok "CoT + Access Federation bootstrap finished."
echo
log_info "Verify in UI:"
log_info "  art1 → Administration → User Management → Access Federation"
log_info "  art1 → Repositories → generic-fed (Federation tab → members)"
log_info "  art1 → Repositories → docker-fed   (Federation tab → members)"
echo
log_info "Adding more federated members manually? Use docker-internal URLs:"
log_info "  ✓  http://artifactory2:8082/artifactory/<repo>"
log_info "  ✗  http://localhost:8182/artifactory/<repo>   (AF inside its container"
log_info "                                                  can't reach host's localhost)"
