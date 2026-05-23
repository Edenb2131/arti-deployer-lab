#!/usr/bin/env bash
# render-templates.sh — Render all config/**/*.tmpl files into their
# non-.tmpl counterparts by substituting an allowlist of env variables.
#
# This keeps every credential out of git: templates contain `${VAR}`
# placeholders, the rendered outputs are gitignored.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# ─── Allowlist of variables that get substituted ─────────────────────────────
# Only these are expanded; anything else in a template stays literal. This
# avoids accidents where envsubst would gobble unrelated `$something` text.
SUBST_VARS=(
  JOIN_KEY
  MASTER_KEY
  PG_AF1_PASSWORD
  PG_AF2_PASSWORD
  PG_XRAY_PASSWORD
  LDAP_ADMIN_PASSWORD
  LDAP_USER_PASSWORD
  KEYCLOAK_ADMIN_PASSWORD
  KEYCLOAK_CLIENT_SECRET
  XRAY_RABBITMQ_USER
  XRAY_RABBITMQ_PASSWORD
)

# ─── Validate that every required var is non-empty ───────────────────────────
missing=()
for v in "${SUBST_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  log_err "Missing required env vars: ${missing[*]}"
  log_err "Run './arti-deployer init' to auto-generate them, or fill them in .env manually."
  exit 1
fi

# Build the allowlist string for envsubst (format: '${VAR1} ${VAR2} ...')
ALLOWLIST=""
for v in "${SUBST_VARS[@]}"; do
  ALLOWLIST+="\${$v} "
done

# ─── Render every .tmpl in config/ ───────────────────────────────────────────
shopt -s globstar nullglob
rendered=0
for tmpl in "${CONFIG_DIR}"/**/*.tmpl; do
  out="${tmpl%.tmpl}"
  envsubst "${ALLOWLIST}" < "${tmpl}" > "${out}"
  chmod 600 "${out}"
  rendered=$((rendered + 1))
done

log_ok "Rendered ${rendered} template(s) from config/**/*.tmpl"
