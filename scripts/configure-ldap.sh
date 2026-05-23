#!/usr/bin/env bash
# configure-ldap.sh — Wire the OpenLDAP server into Artifactory 1.
# Uses the system configuration PATCH API to add an LDAP server + group
# settings. Idempotent: marker file prevents re-runs.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_ROUTER_PORT}"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"
LDAP_KEY="ldap-local"

MARKER="${STATE_DIR}/.ldap-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "LDAP already configured. Delete ${MARKER} to re-run."
  exit 0
fi

# Wait briefly for LDAP container to settle (separate from AF healthcheck)
log_info "Waiting 10s for OpenLDAP to finish ldif import..."
sleep 10

# Build the YAML patch payload
PATCH_YAML=$(cat <<EOF
security:
  ldapSettings:
    ${LDAP_KEY}:
      enabled: true
      ldapUrl: ldap://openldap:1389/dc=jfrog,dc=local
      userDnPattern: "uid={0},ou=users"
      search:
        searchFilter: "(uid={0})"
        searchBase: "ou=users"
        searchSubTree: true
        managerDn: "cn=admin,dc=jfrog,dc=local"
        managerPassword: "${LDAP_ADMIN_PASSWORD}"
      autoCreateUser: true
      emailAttribute: mail
      ldapPoisoningProtection: true
  ldapGroupSettings:
    ldap-groups-local:
      name: ldap-groups-local
      groupBaseDn: "ou=groups,dc=jfrog,dc=local"
      groupNameAttribute: cn
      groupMemberAttribute: member
      subTree: true
      filter: "(objectClass=groupOfNames)"
      descriptionAttribute: description
      strategy: STATIC
      enabledLdap: ${LDAP_KEY}
EOF
)

log_info "Applying LDAP system configuration patch to art1..."
http_code=$(curl -sS -o /tmp/af-ldap-resp.txt -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X PATCH \
  -H 'Content-Type: application/yaml' \
  --data "${PATCH_YAML}" \
  "${AF1_URL}/artifactory/api/system/configuration")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "LDAP wired into art1 (HTTP ${http_code})."
  log_info "Test login: alice / Password123 — should auto-create AF user."
  touch "${MARKER}"
else
  log_err "LDAP patch failed (HTTP ${http_code}). Response:"
  cat /tmp/af-ldap-resp.txt >&2
  log_warn "You can fix this manually in: Administration → Security → LDAP"
  exit 1
fi
