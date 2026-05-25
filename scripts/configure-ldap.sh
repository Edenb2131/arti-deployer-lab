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

# ─── 3. Materialize AF groups that match the LDIF fixture ────────────────────
# AF's LDAP group resolution at login only assigns the user to AF groups
# that already exist with matching names. Registering the LDAP group filter
# above tells AF *how* to find LDAP groups, but doesn't create the AF-side
# group records. Without this step, user1/user2/user3 log in and get only
# the default 'readers' group.
#
# Names must match config/ldap/ldifs/03-groups.ldif.tmpl exactly.
# 'admins' is created with adminPrivileges=true (= "Platform Administrator"
# in the UI) so user1 (sole member of cn=admins in the LDIF) gets full
# admin rights on next UI login.
log_info "Creating matching AF groups (one per LDAP group in the fixture)..."
af_group_upsert() {
  local name="$1" desc="$2" admin_priv="${3:-false}"
  local payload code verb
  payload=$(jq -nc \
    --arg name "${name}" --arg desc "${desc}" --argjson admin "${admin_priv}" \
    '{name:$name, description:$desc, autoJoin:false, realm:"ldap",
      adminPrivileges:$admin}')
  # AF API: PUT creates (201 / 409), POST updates an existing record. There
  # is no single upsert verb. Try PUT first; on 409 (already exists) fall
  # back to POST so adminPrivileges / description changes still land on
  # re-runs.
  verb="PUT"
  code=$(curl -sS -o /tmp/af-grp-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${AF1_URL}/artifactory/api/security/groups/${name}")
  if [[ "${code}" == "409" ]]; then
    verb="POST"
    code=$(curl -sS -o /tmp/af-grp-resp.txt -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X POST -H 'Content-Type: application/json' \
      --data "${payload}" \
      "${AF1_URL}/artifactory/api/security/groups/${name}")
  fi
  case "${code}" in
    20*) printf '  ✓ %-12s admin=%s (HTTP %s via %s)\n' "${name}" "${admin_priv}" "${code}" "${verb}" ;;
    *)   printf '  ✗ %-12s HTTP %s via %s: %s\n'        "${name}" "${code}" "${verb}" "$(head -c 200 /tmp/af-grp-resp.txt)" ;;
  esac
}

af_group_upsert "group1"     "Legacy compat group (user1, user2) — LDAP-bound"      false
af_group_upsert "group2"     "Legacy compat group (user2, user3) — LDAP-bound"      false
af_group_upsert "developers" "Developers role — LDAP-bound"                          false
af_group_upsert "qa"         "QA role — LDAP-bound"                                  false
af_group_upsert "admins"     "Platform Administrators (LDAP-bound, full admin)"     true

touch "${MARKER}"
log_ok "LDAP integration complete."
log_info "Test login: user1 / \$LDAP_USER_PASSWORD (see .env) — auto-creates AF user."
log_info "Groups (openldap-groups, dn=ou=Groups,ou=Organization,dc=example,dc=org):"
log_info "  group1      → user1, user2          (legacy compat, narrowed)"
log_info "  group2      → user2, user3          (overlaps group1 via user2)"
log_info "  developers  → user1, user2"
log_info "  qa          → user3"
log_info "  admins      → user1"
log_info "  user4       → no group memberships  (deliberate repro case)"
