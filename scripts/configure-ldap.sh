#!/usr/bin/env bash
# configure-ldap.sh — Wire the OpenLDAP server into Artifactory 1.
# Uses the same /artifactory/ui/ldap and /artifactory/ui/ldapgroups/ldapgroup
# endpoints as ldapsetupforartifactory's newscript.sh.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_HTTP_PORT}"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"

MARKER="${STATE_DIR}/.ldap-configured"
if [[ -f "${MARKER}" ]]; then
  log_info "LDAP already configured. Delete ${MARKER} to re-run."
  exit 0
fi

log_info "Waiting 10s for OpenLDAP to finish ldif import..."
sleep 10

# ─── 1. LDAP server settings ─────────────────────────────────────────────────
ldap_payload=$(jq -nc \
  --arg pw "${LDAP_ADMIN_PASSWORD}" \
  '{
    enabled: true,
    autoCreateUser: true,
    search: {
      searchSubTree: true,
      searchFilter: "(uid={0})",
      managerDn: "cn=admin,dc=example,dc=org",
      managerPassword: $pw
    },
    emailAttribute: "mail",
    ldapPoisoningProtection: true,
    key: "openldap",
    ldapUrl: "ldap://openldap:389/dc=example,dc=org"
  }')

log_info "POST /artifactory/ui/ldap ..."
http_code=$(curl -sS -o /tmp/af-ldap-resp.txt -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X POST -H 'Content-Type: application/json' \
  --data "${ldap_payload}" \
  "${AF1_URL}/artifactory/ui/ldap")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "LDAP server registered (HTTP ${http_code})."
else
  log_err "LDAP registration failed (HTTP ${http_code}):"
  cat /tmp/af-ldap-resp.txt >&2
  log_warn "Manually configure: Administration → Security → LDAP"
  exit 1
fi

# ─── 2. LDAP group settings ──────────────────────────────────────────────────
group_payload=$(jq -nc '{
  name: "openldap-groups",
  groupNameAttribute: "cn",
  groupMemberAttribute: "member",
  subTree: true,
  filter: "(objectClass=groupOfNames)",
  descriptionAttribute: "description",
  enabledLdap: "openldap",
  strategy: "STATIC",
  enabled: true
}')

log_info "POST /artifactory/ui/ldapgroups/ldapgroup ..."
http_code=$(curl -sS -o /tmp/af-ldapgroup-resp.txt -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X POST -H 'Content-Type: application/json' \
  --data "${group_payload}" \
  "${AF1_URL}/artifactory/ui/ldapgroups/ldapgroup")

if [[ "${http_code}" =~ ^2 ]]; then
  log_ok "LDAP groups configured (HTTP ${http_code})."
else
  log_warn "LDAP group config returned HTTP ${http_code}. Response:"
  cat /tmp/af-ldapgroup-resp.txt
  log_warn "Manually configure: Administration → Security → LDAP Groups"
fi

touch "${MARKER}"
log_ok "LDAP integration complete."
log_info "Test login: user1 / \$LDAP_USER_PASSWORD (see .env) — auto-creates AF user."
log_info "Groups: openldap-groups → group1, group2 (each contains user1, user2, user3)"
