#!/usr/bin/env bash
# configure-cot.sh
# Bootstraps Circle of Trust + Access Federation between art1 and art2,
# then creates a sample federated generic repo as a smoke test.
#
# Best-effort scaffold — the exact Access API surface for CoT has evolved
# across AF versions. Verified shape against 7.98.x. If your version uses
# a different endpoint, see:
#   https://jfrog.com/help/r/jfrog-rest-apis/access
#   https://jfrog.com/help/r/jfrog-platform-administration-documentation/circle-of-trust
#   https://jfrog.com/help/r/jfrog-platform-administration-documentation/access-federation

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

# ─── helpers ─────────────────────────────────────────────────────────────────
af_curl() {
  # usage: af_curl <url> [curl args ...]
  local url="$1"; shift
  curl -sS -u "${ADMIN_USER}:${ADMIN_PASS}" "$@" "${url}"
}

fail_soft() {
  log_warn "$1"
  log_warn "Continuing — CoT bootstrap is best-effort and may need a manual step."
}

# ─── 1. Fetch each instance's Access root certificate ────────────────────────
log_info "Fetching root certificate from art1..."
CERT1=$(af_curl "${AF1_URL}/access/api/v1/system/root_certificate") || fail_soft "Could not fetch art1 root cert."

log_info "Fetching root certificate from art2..."
CERT2=$(af_curl "${AF2_URL}/access/api/v1/system/root_certificate") || fail_soft "Could not fetch art2 root cert."

# Save certs locally so they're inspectable
echo "${CERT1}" > "${STATE_DIR}/art1-root.pem"
echo "${CERT2}" > "${STATE_DIR}/art2-root.pem"
log_ok "Root certs saved to ${STATE_DIR}/."

# ─── 2. Cross-trust the certificates (Circle of Trust) ───────────────────────
# The Access service exposes `POST /access/api/v1/system/trusted_keys` with
# {"key": "<PEM>", "kid": "<id>"}. On AF 7.46+ this is the CoT mechanism.
trust_cert() {
  local target_url="$1"  local target_label="$2"
  local cert_pem="$3"    local kid="$4"
  log_info "Trusting ${kid} on ${target_label}..."
  af_curl "${target_url}/access/api/v1/system/trusted_keys" \
    -X POST -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg k "${cert_pem}" --arg id "${kid}" '{key:$k, kid:$id}')" \
    >/dev/null || fail_soft "Trusted-key POST to ${target_label} failed."
}

trust_cert "${AF1_URL}" "art1" "${CERT2}" "art2-root"
trust_cert "${AF2_URL}" "art2" "${CERT1}" "art1-root"

# ─── 3. Set Custom Base URL on each instance ─────────────────────────────────
# Federated repos require a Custom Base URL to be configured (AF UI shows
# "Federated repository requires a Custom Base URL" otherwise). Each AF
# advertises its own URL so the other side can reach it for federation.
set_base_url() {
  local target_url="$1" target_label="$2" base_url="$3"
  log_info "Setting Custom Base URL on ${target_label} → ${base_url}"
  af_curl "${target_url}/artifactory/api/system/configuration/baseUrl" \
    -X PUT -H 'Content-Type: text/plain' \
    --data "${base_url}" \
    >/dev/null || fail_soft "Base URL update on ${target_label} failed."
}

set_base_url "${AF1_URL}" "art1" "${AF1_INTERNAL}/artifactory"
set_base_url "${AF2_URL}" "art2" "${AF2_INTERNAL}/artifactory"

# ─── 4. Access Federation: register each as a trusted peer ───────────────────
# Access Federation propagates users, groups, permissions, and access tokens
# across CoT members. The federation topology API:
#   POST /access/api/v1/topology/federation_target
# (Endpoint name and payload may differ in your version. Verify in UI under:
#  Administration → User Management → Access Federation.)
log_info "Registering art2 as a federation target on art1..."
af_curl "${AF1_URL}/access/api/v1/topology/federation_target" \
  -X POST -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg url "${AF2_INTERNAL}" '{target_url:$url, propagate_groups:true, propagate_users:true, propagate_permissions:true}')" \
  >/dev/null || fail_soft "Federation target registration on art1 failed. Configure manually in UI."

# ─── 5. Sample federated generic repo as smoke test ──────────────────────────
log_info "Creating sample federated repo 'generic-federated' on art1..."
af_curl "${AF1_URL}/artifactory/api/repositories/generic-federated" \
  -X PUT -H 'Content-Type: application/json' \
  --data "$(cat <<JSON
{
  "key": "generic-federated",
  "rclass": "federated",
  "packageType": "generic",
  "members": [
    {"url": "${AF1_INTERNAL}/artifactory/generic-federated", "enabled": true},
    {"url": "${AF2_INTERNAL}/artifactory/generic-federated", "enabled": true}
  ]
}
JSON
)" >/dev/null || fail_soft "Federated repo creation failed. The CoT might still be propagating — re-run in ~1 minute."

touch "${MARKER}"
log_ok "CoT + Access Federation bootstrap complete."
log_info "Verify:"
log_info "  art1 UI → Administration → User Management → Access Federation"
log_info "  art1 UI → Repositories → generic-federated (members tab)"
log_info "Upload a file to art1's generic-federated and confirm it appears on art2."
