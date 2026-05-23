#!/usr/bin/env bash
# configure-keycloak.sh — Register Keycloak as an OIDC provider in AF 1.
# Uses the Access OIDC API; best-effort across versions.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_ROUTER_PORT}"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"

# Use the internal docker network hostname — both containers are on arti-net.
KC_INTERNAL_ISSUER="http://keycloak:8080/realms/jfrog"
# For browser redirects, users hit Keycloak on the host port.
KC_PUBLIC_ISSUER="http://localhost:${KEYCLOAK_PORT}/realms/jfrog"

MARKER="${STATE_DIR}/.keycloak-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "Keycloak already configured. Delete ${MARKER} to re-run."
  exit 0
fi

log_info "Waiting for Keycloak readiness..."
elapsed=0
until curl -sf -o /dev/null -m 5 "http://localhost:${KEYCLOAK_PORT}/realms/jfrog/.well-known/openid-configuration"; do
  sleep 3
  elapsed=$((elapsed + 3))
  if (( elapsed > 120 )); then
    log_err "Keycloak realm 'jfrog' not reachable. Check 'docker logs arti-keycloak'."
    exit 1
  fi
done
log_ok "Keycloak realm 'jfrog' is reachable."

# ─── 1. Register OIDC provider in Access ─────────────────────────────────────
log_info "Registering Keycloak as OIDC provider in AF Access..."
oidc_payload=$(jq -nc \
  --arg name "keycloak" \
  --arg issuer "${KC_PUBLIC_ISSUER}" \
  --arg client_id "artifactory" \
  '{
     name: $name,
     issuer_url: $issuer,
     provider_type: "GENERIC",
     client_id: $client_id,
     audience: $client_id,
     enable_token_issuance_via_api: true
   }')

http_code=$(curl -sS -o /tmp/af-oidc-resp.txt -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X POST -H 'Content-Type: application/json' \
  --data "${oidc_payload}" \
  "${AF1_URL}/access/api/v1/oidc")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "OIDC provider 'keycloak' registered in Access (HTTP ${http_code})."
else
  log_warn "OIDC registration returned HTTP ${http_code}. Response:"
  cat /tmp/af-oidc-resp.txt
  log_warn "You can finish setup manually:"
  log_warn "  Administration → Identity Providers → OIDC → Add"
  log_warn "  Issuer URL: ${KC_PUBLIC_ISSUER}"
  log_warn "  Client ID:  artifactory"
  log_warn "  Secret:     artifactory-client-secret"
fi

# ─── 2. (Optional) Configure OAuth SSO settings via system config ────────────
# This step adds Keycloak as a usable SSO source in the AF login page.
log_info "Enabling OAuth SSO via Keycloak in AF system config..."
PATCH_YAML=$(cat <<EOF
security:
  oauthSettings:
    enableIntegration: true
    persistUsers: true
    allowUserToAccessProfile: true
    oauthProvidersSettings:
      keycloak:
        id: keycloak
        enabled: true
        providerType: openId
        clientId: artifactory
        clientSecret: artifactory-client-secret
        authUrl: ${KC_PUBLIC_ISSUER}/protocol/openid-connect/auth
        tokenUrl: ${KC_INTERNAL_ISSUER}/protocol/openid-connect/token
        apiUrl: ${KC_INTERNAL_ISSUER}/protocol/openid-connect/userinfo
        domain: ""
        basicUrl: ${KC_INTERNAL_ISSUER}
EOF
)

http_code=$(curl -sS -o /tmp/af-oauth-resp.txt -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X PATCH -H 'Content-Type: application/yaml' \
  --data "${PATCH_YAML}" \
  "${AF1_URL}/artifactory/api/system/configuration")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "OAuth SSO enabled in system config (HTTP ${http_code})."
else
  log_warn "OAuth SSO patch returned HTTP ${http_code}. Response:"
  cat /tmp/af-oauth-resp.txt
  log_warn "Configure manually: Administration → Security → OAuth SSO"
fi

touch "${MARKER}"
log_ok "Keycloak integration bootstrap complete."
log_info "Try logging into AF UI — you should see a 'Sign in with keycloak' button."
log_info "Test creds: testuser / Password123  (or kcadmin / Password123)"
