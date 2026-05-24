#!/usr/bin/env bash
# configure-cot.sh — Simple, clean CoT + federation between art1 and art2.
#
# What it does
#   1. Copies each AF's /etc/access/keys/root.crt into the OTHER AF's
#      /etc/access/keys/trusted/ directory via `docker cp`. Access service
#      auto-ingests them (the files disappear within ~30s, moved into the
#      Access DB). That's the entire Circle of Trust mechanism — it's a
#      filesystem operation, not an API call.
#   2. Sets each AF's Custom Base URL to its docker-internal hostname so
#      federated repos can reach each other over the bridge net.
#   3. Creates sample federated repos (generic-fed, docker-fed) with both
#      AFs as members.
#
# Auth used: admin / password on /artifactory/api/* endpoints. That's all.
# No Access-API admin token needed, no Mission Control pairing token, no
# UI clicks.
#
# Verified working against AF 7.146.13 with both instances on the
# arti-deployer_net bridge network.

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

# ─── 1. Cross-trust the Access root certificates ─────────────────────────────
# This is what the JFrog docs call "Step 2: Creating Circle of Trust" — a
# file-level operation. Access on each side ingests the cert into its DB
# (the file disappears from trusted/ within ~30s), and from that point on
# tokens signed by the other JPD validate cleanly.
log_step "Cross-trusting Access root certs (filesystem CoT)"

local_root_art1=$(mktemp)
local_root_art2=$(mktemp)
trap 'rm -f "${local_root_art1}" "${local_root_art2}"' EXIT

log_info "Pulling root.crt from each AF to host..."
docker cp "artifactory1:${KEYS_DIR}/root.crt" "${local_root_art1}"
docker cp "artifactory2:${KEYS_DIR}/root.crt" "${local_root_art2}"

log_info "Dropping into the other AF's trusted/ dir..."
docker cp "${local_root_art2}" "artifactory1:${KEYS_DIR}/trusted/art2-root.crt"
docker cp "${local_root_art1}" "artifactory2:${KEYS_DIR}/trusted/art1-root.crt"

# Ensure AF user (uid 1030) can read — docker cp lands as root by default.
docker exec --user root artifactory1 chown 1030:1030 "${KEYS_DIR}/trusted/art2-root.crt" 2>/dev/null || true
docker exec --user root artifactory2 chown 1030:1030 "${KEYS_DIR}/trusted/art1-root.crt" 2>/dev/null || true

log_info "Waiting for Access to ingest the certs (files vanish when imported)..."
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
if [[ -n "${a1}" || -n "${a2}" ]]; then
  log_warn "Certs still present in trusted/ after ${elapsed}s — Access may not have picked them up."
  log_warn "Try restarting AF: ./arti-deployer down && ./arti-deployer up"
fi

# ─── 2. Set Custom Base URLs ─────────────────────────────────────────────────
# Federated repos require a Base URL on each member — otherwise the UI
# rejects them with "Federated repository requires a Custom Base URL".
# Both AFs advertise their docker-internal hostname so federation members
# can reach each other over the bridge net (NOT localhost — see step 3).
log_step "Setting Custom Base URLs"
set_base_url() {
  local af_url="$1" label="$2" base_url="$3"
  log_info "${label}: ${base_url}"
  local code
  code=$(curl -sS -o /tmp/af-base-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: text/plain' \
    --data "${base_url}" \
    "${af_url}/artifactory/api/system/configuration/baseUrl")
  if [[ "${code}" =~ ^2 ]]; then
    log_ok "${label} base URL set (HTTP ${code})."
  else
    log_warn "Base URL PUT on ${label} returned ${code}: $(cat /tmp/af-base-resp.txt)"
  fi
}
set_base_url "${AF1_URL}" "art1" "${AF1_INTERNAL}/artifactory"
set_base_url "${AF2_URL}" "art2" "${AF2_INTERNAL}/artifactory"

# ─── 3. Create sample federated repos ────────────────────────────────────────
# IMPORTANT — member URLs MUST use the docker-internal hostname
# (http://artifactory{1,2}:8082/...). AF inside its container can't reach
# the host's localhost:8082 — that's the most common federation pitfall.
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
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${AF1_URL}/artifactory/api/repositories/${repo_key}")
  case "${code}" in
    20*) log_ok "Created federated repo '${repo_key}' (${package_type}, HTTP ${code})." ;;
    400)
      # AF returns 400 (not 409) when the repo key already exists
      # case-insensitively. Treat as already-exists.
      if grep -q 'already exists' /tmp/af-repo-resp.txt; then
        log_info "Repo '${repo_key}' already exists — skipping."
      else
        log_warn "Repo '${repo_key}' rejected (HTTP 400): $(cat /tmp/af-repo-resp.txt)"
      fi
      ;;
    409) log_info "Repo '${repo_key}' already exists (HTTP 409 — skipping)." ;;
    *)   log_warn "Repo '${repo_key}' create returned HTTP ${code}: $(cat /tmp/af-repo-resp.txt)" ;;
  esac
}
create_federated_repo "generic-fed" "generic"
create_federated_repo "docker-fed"  "docker"

# ─── 4. Smoke test: upload to art1, confirm it lands on art2 ─────────────────
log_step "Verifying federation replication (smoke test)"
test_file=$(mktemp)
echo "arti-deployer-cot-smoke-$(date +%s)" > "${test_file}"
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X PUT --data-binary "@${test_file}" \
  "${AF1_URL}/artifactory/generic-fed/cot-smoke.txt" >/dev/null && \
  log_info "Uploaded test file to art1 generic-fed."

log_info "Polling art2 (up to 60s)..."
elapsed=0
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
  log_warn "✗ Test file did NOT replicate to art2 within ${elapsed}s."
  log_warn "Check art1 logs: docker logs artifactory1 | grep -i federation"
fi
rm -f "${test_file}"
curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" -X DELETE \
  "${AF1_URL}/artifactory/generic-fed/cot-smoke.txt" >/dev/null 2>&1 || true

touch "${MARKER}"
echo
log_ok "CoT + Federation bootstrap complete."
log_info "Federated repos: generic-fed, docker-fed (both on art1 and art2)"
log_info "Upload to art1's generic-fed → replicates to art2 within ~30s."
log_info ""
log_info "Adding more federated members? Use docker-internal URLs:"
log_info "  ✓  http://artifactory2:8082/artifactory/<repo>"
log_info "  ✗  http://localhost:8182/artifactory/<repo>   (AF container can't"
log_info "                                                  reach host's localhost)"
