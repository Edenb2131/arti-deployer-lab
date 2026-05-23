#!/usr/bin/env bash
# configure-keycloak.sh — Register Keycloak as an OIDC provider in AF 7.100+.
#
# Two-step setup:
#   1. POST /access/api/v1/oidc                       (modern Access API,
#                                                      Bearer-token auth)
#   2. POST /access/api/v1/oidc/<name>/identity_mappings
#      Maps a Keycloak claim → AF user/scope so OIDC token exchange works.
#   3. PATCH /artifactory/api/system/configuration
#      Adds 'Sign in with Keycloak' SSO button on the AF login page.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_ROUTER_PORT}"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"
KC_PUBLIC_ISSUER="http://localhost:${KEYCLOAK_PORT}/realms/jfrog"
KC_INTERNAL_ISSUER="http://keycloak:8080/realms/jfrog"
PROVIDER_NAME="keycloak"

MARKER="${STATE_DIR}/.keycloak-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "Keycloak already configured. Delete ${MARKER} to re-run."
  exit 0
fi

# ─── Wait for Keycloak realm to be reachable ─────────────────────────────────
log_info "Waiting for Keycloak realm '${PROVIDER_NAME}'..."
elapsed=0
until curl -sf -o /dev/null -m 5 "${KC_PUBLIC_ISSUER}/.well-known/openid-configuration"; do
  sleep 3
  elapsed=$((elapsed + 3))
  if (( elapsed > 120 )); then
    log_err "Keycloak realm 'jfrog' not reachable. Check 'docker logs arti-keycloak'."
    exit 1
  fi
done
log_ok "Keycloak realm is reachable."

# ─── Get an admin bearer token from Access ───────────────────────────────────
# /access/api/v1/* endpoints require Bearer auth as of AF 7.100+.
log_info "Exchanging admin basic creds for an Access bearer token..."
TOKEN=$(af_admin_token "${AF1_URL}")
if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  log_err "Failed to get an admin token from /access/api/v1/tokens."
  log_err "Make sure AF1 is up and admin password matches AF_ADMIN_PASSWORD in .env."
  exit 1
fi
log_ok "Bearer token acquired."

auth_header=(-H "Authorization: Bearer ${TOKEN}")

# ─── 1. Register the OIDC provider ───────────────────────────────────────────
# Schema per docs.jfrog.com /administration/reference/createOidcConfiguration
# Required: name, issuer_url, audience, provider_type
log_info "POST /access/api/v1/oidc ..."
oidc_body=$(jq -nc \
  --arg name "${PROVIDER_NAME}" \
  --arg issuer "${KC_PUBLIC_ISSUER}" \
  --arg audience "artifactory" \
  '{
    name: $name,
    issuer_url: $issuer,
    audience: $audience,
    description: "Keycloak OIDC integration (arti-deployer-lab)",
    provider_type: "generic",
    enable_permissive_configuration: false,
    use_default_proxy: false
  }')

http_code=$(curl -sS -o /tmp/af-oidc-resp.txt -w '%{http_code}' \
  "${auth_header[@]}" \
  -X POST -H 'Content-Type: application/json' \
  --data "${oidc_body}" \
  "${AF1_URL}/access/api/v1/oidc")

case "${http_code}" in
  20*)
    log_ok "OIDC provider '${PROVIDER_NAME}' registered (HTTP ${http_code})."
    ;;
  409)
    log_info "OIDC provider already exists — skipping create."
    ;;
  *)
    log_err "OIDC registration failed (HTTP ${http_code}):"
    cat /tmp/af-oidc-resp.txt >&2
    log_warn "Configure manually: Administration → Identity Providers → OIDC"
    ;;
esac

# ─── 2. Identity mapping (claim → AF user) ───────────────────────────────────
# Lets `testuser` from Keycloak exchange a Keycloak token for an AF token
# scoped as a 'readers' group member.
log_info "POST /access/api/v1/oidc/${PROVIDER_NAME}/identity_mappings ..."
mapping_body=$(jq -nc '{
  name: "keycloak-testuser",
  description: "Maps Keycloak testuser → AF user (readers scope)",
  priority: 1,
  claims: {
    preferred_username: "testuser"
  },
  token_spec: {
    username: "testuser",
    scope: "applied-permissions/groups:readers",
    expires_in: 7200
  }
}')

http_code=$(curl -sS -o /tmp/af-oidc-map-resp.txt -w '%{http_code}' \
  "${auth_header[@]}" \
  -X POST -H 'Content-Type: application/json' \
  --data "${mapping_body}" \
  "${AF1_URL}/access/api/v1/oidc/${PROVIDER_NAME}/identity_mappings")

case "${http_code}" in
  20*) log_ok "Identity mapping 'keycloak-testuser' created (HTTP ${http_code})." ;;
  409) log_info "Identity mapping already exists — skipping." ;;
  *)
    log_warn "Mapping creation returned HTTP ${http_code}. Response:"
    cat /tmp/af-oidc-map-resp.txt
    log_warn "Configure manually in OIDC provider settings."
    ;;
esac

# ─── 3. Enable interactive OAuth SSO ('Sign in with Keycloak' button) ────────
# Token exchange (steps 1+2) is for CI/CD and machine-to-machine auth.
# For user UI login via Keycloak, AF still uses the separate oauthSettings.
log_info "Enabling interactive OAuth SSO in AF system config..."
sso_yaml=$(cat <<EOF
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
        clientSecret: ${KEYCLOAK_CLIENT_SECRET}
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
  --data "${sso_yaml}" \
  "${AF1_URL}/artifactory/api/system/configuration")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "OAuth SSO enabled (HTTP ${http_code})."
else
  log_warn "OAuth SSO patch returned HTTP ${http_code}. Response:"
  cat /tmp/af-oauth-resp.txt
  log_warn "Configure manually: Administration → Security → OAuth SSO"
fi

touch "${MARKER}"
log_ok "Keycloak integration complete."
log_info "UI login:  http://localhost:${AF1_HTTP_PORT}/ui/ → 'Sign in with keycloak'"
log_info "Test user: testuser / \$LDAP_USER_PASSWORD  (or kcadmin same password)"
log_info "Token exchange (CI/CD):"
log_info "  POST ${AF1_URL}/access/api/v1/oidc/token"
log_info "  Body: {subject_token: '<kc_token>', subject_token_type: 'urn:ietf:params:oauth:token-type:id_token', provider_name: 'keycloak'}"
