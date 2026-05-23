#!/usr/bin/env bash
# init-env.sh — Bootstrap .env from .env.example with auto-generated secrets.
# Idempotent: if .env already exists, prompts before overwriting.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

if [[ -f "${ENV_FILE}" ]]; then
  log_warn ".env already exists. Overwrite would lose any custom values."
  if ! gum confirm "Overwrite existing .env with a fresh bootstrap?"; then
    log_info "Keeping existing .env. Exiting."
    exit 0
  fi
fi

# ─── Generate secrets ────────────────────────────────────────────────────────
log_info "Generating fresh secrets with openssl rand..."

gen_hex32()   { openssl rand -hex 16; }            # 32 hex chars (joinKey/masterKey)
gen_passwd()  { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

JOIN_KEY_VAL=$(gen_hex32)
MASTER_KEY_VAL=$(gen_hex32)
PG_AF1_VAL=$(gen_passwd)
PG_AF2_VAL=$(gen_passwd)
PG_XRAY_VAL=$(gen_passwd)
LDAP_ADMIN_VAL=$(gen_passwd)
LDAP_USER_VAL=$(gen_passwd)
KC_ADMIN_VAL=$(gen_passwd)
KC_CLIENT_VAL=$(gen_passwd)
RABBIT_PASS_VAL=$(gen_passwd)

# ─── Build .env by copying .env.example and replacing empty values ───────────
cp "${ENV_EXAMPLE}" "${ENV_FILE}"

# sed -i differs on macOS vs Linux; portable form: use a temp file
set_var() {
  local key="$1" val="$2"
  # Escape & and / and \ for the replacement side
  local esc
  esc=$(printf '%s' "${val}" | sed -e 's/[\/&]/\\&/g')
  sed -e "s|^${key}=.*|${key}=${esc}|" "${ENV_FILE}" > "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "${ENV_FILE}"
}

set_var JOIN_KEY               "${JOIN_KEY_VAL}"
set_var MASTER_KEY             "${MASTER_KEY_VAL}"
set_var PG_AF1_PASSWORD        "${PG_AF1_VAL}"
set_var PG_AF2_PASSWORD        "${PG_AF2_VAL}"
set_var PG_XRAY_PASSWORD       "${PG_XRAY_VAL}"
set_var LDAP_ADMIN_PASSWORD    "${LDAP_ADMIN_VAL}"
set_var LDAP_USER_PASSWORD     "${LDAP_USER_VAL}"
set_var KEYCLOAK_ADMIN_PASSWORD "${KC_ADMIN_VAL}"
set_var KEYCLOAK_CLIENT_SECRET "${KC_CLIENT_VAL}"
set_var XRAY_RABBITMQ_PASSWORD "${RABBIT_PASS_VAL}"

chmod 600 "${ENV_FILE}"

log_ok "Bootstrapped ${ENV_FILE} with fresh secrets."
echo
log_warn "ARTIFACTORY_LICENSE is still empty — paste your license into .env before running 'up'."
log_info "Or set ARTIFACTORY_LICENSE_FILE=/absolute/path/to/artifactory.lic"
echo
log_info "Sample LDAP user password (alice/bob/carol): ${LDAP_USER_VAL}"
log_info "Sample Keycloak user password (testuser/kcadmin): see .env (KEYCLOAK_*)"
log_info "These are also in your .env — do NOT share or commit it."
