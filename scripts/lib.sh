# shellcheck shell=bash
# Shared helpers for arti-deployer. Source this — do not execute.

set -o pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${ROOT_DIR}/compose"
CONFIG_DIR="${ROOT_DIR}/config"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
STATE_DIR="${ROOT_DIR}/.arti-deployer"

mkdir -p "${STATE_DIR}"

# ─── Logging ─────────────────────────────────────────────────────────────────
log_info()  { gum style --foreground 212 "▸ $*"; }
log_ok()    { gum style --foreground 46  "✔ $*"; }
log_warn()  { gum style --foreground 214 "⚠ $*"; }
log_err()   { gum style --foreground 196 "✖ $*" >&2; }
log_step()  { gum style --bold --foreground 51 --margin "1 0 0 0" "── $* ──"; }

# ─── Dependency check ────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for bin in docker gum jq curl openssl envsubst; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker-compose-v2")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing dependencies: ${missing[*]}"
    cat >&2 <<EOF

Install on macOS with Homebrew:
  brew install gum jq gettext   # gettext provides envsubst

Docker Desktop (or Colima) must be running and provide 'docker compose'.

EOF
    exit 1
  fi
}

# ─── Env loading ─────────────────────────────────────────────────────────────
load_env() {
  if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    log_err ".env not found."
    log_info "Run './arti-deployer init' to bootstrap a .env with fresh secrets."
    exit 1
  fi
  # shellcheck disable=SC1090,SC1091
  set -a; source "${ROOT_DIR}/.env"; set +a
}

# ─── .env updater ────────────────────────────────────────────────────────────
# Writes KEY=VAL in .env (replaces existing line or appends). Also updates
# the in-memory variable so subsequent steps in the same run see the change.
update_env_var() {
  local key="$1" val="$2"
  local env_file="${ROOT_DIR}/.env"
  # Escape sed delimiters in the replacement
  local esc
  esc=$(printf '%s' "${val}" | sed -e 's/[\/&|]/\\&/g')
  if grep -q "^${key}=" "${env_file}" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${esc}|" "${env_file}" && rm -f "${env_file}.bak"
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${env_file}"
  fi
  # Mirror in-memory for the rest of this run
  printf -v "${key}" '%s' "${val}"
  export "${key}"
}

# ─── License handling ────────────────────────────────────────────────────────
# Writes config/<instance>/artifactory.lic from .env. Errors if no license set.
# For art2, prefers ARTIFACTORY_LICENSE_2 / ARTIFACTORY_LICENSE_FILE_2 and
# falls back to the art1 license with a warning (JFrog logs a license
# conflict but the lab still functions for dev/test).
write_license() {
  local instance="$1"  # art1 or art2
  local dest="${CONFIG_DIR}/${instance}/artifactory.lic"
  local license_text="" license_path=""

  if [[ "${instance}" == "art2" ]]; then
    license_text="${ARTIFACTORY_LICENSE_2:-}"
    license_path="${ARTIFACTORY_LICENSE_FILE_2:-}"
    if [[ -z "${license_text}" && -z "${license_path}" ]]; then
      log_warn "ARTIFACTORY_LICENSE_2 not set — reusing art1 license for art2."
      log_warn "JFrog will log a license conflict on art2. Lab still functional."
      license_text="${ARTIFACTORY_LICENSE:-}"
      license_path="${ARTIFACTORY_LICENSE_FILE:-}"
    fi
  else
    license_text="${ARTIFACTORY_LICENSE:-}"
    license_path="${ARTIFACTORY_LICENSE_FILE:-}"
  fi

  if [[ -n "${license_path}" ]]; then
    if [[ ! -f "${license_path}" ]]; then
      log_err "License file not found: ${license_path}"
      exit 1
    fi
    cp "${license_path}" "${dest}"
  elif [[ -n "${license_text}" ]]; then
    printf '%b\n' "${license_text}" > "${dest}"
  else
    log_err "No Artifactory license configured for ${instance}. Set ARTIFACTORY_LICENSE (or _2 for art2) in .env."
    exit 1
  fi
  chmod 600 "${dest}"
}

# ─── Compose file chain builder ──────────────────────────────────────────────
# Echoes the `-f a -f b -f c` chain for the selected topology + overlays.
# Globals (set by the wizard):
#   INSTANCE_COUNT  (1 or 2)
#   USE_NGINX       (0/1)
#   USE_NGINX_HTTPS (0/1)
#   USE_LDAP        (0/1)
#   USE_KEYCLOAK    (0/1)
#   USE_XRAY        (0/1)
build_compose_chain() {
  local chain=()
  chain+=("-f" "${COMPOSE_DIR}/art1.yml")
  [[ "${INSTANCE_COUNT}" == "2" ]] && chain+=("-f" "${COMPOSE_DIR}/art2.yml")
  # NGINX: HTTPS variant is standalone (supersedes HTTP), to avoid mount conflicts
  if [[ "${USE_NGINX_HTTPS}" == "1" ]]; then
    chain+=("-f" "${COMPOSE_DIR}/nginx-https.yml")
  elif [[ "${USE_NGINX}" == "1" ]]; then
    chain+=("-f" "${COMPOSE_DIR}/nginx.yml")
  fi
  [[ "${USE_LDAP}" == "1"     ]] && chain+=("-f" "${COMPOSE_DIR}/ldap.yml")
  [[ "${USE_KEYCLOAK}" == "1" ]] && chain+=("-f" "${COMPOSE_DIR}/keycloak.yml")
  [[ "${USE_XRAY}" == "1"     ]] && chain+=("-f" "${COMPOSE_DIR}/xray.yml")
  printf '%s\n' "${chain[@]}"
}

# Saves selections to state for `down`, `logs`, `status` to know which
# compose files to target.
save_selection() {
  cat > "${STATE_DIR}/selection.env" <<EOF
INSTANCE_COUNT=${INSTANCE_COUNT}
USE_NGINX=${USE_NGINX}
USE_NGINX_HTTPS=${USE_NGINX_HTTPS}
USE_LDAP=${USE_LDAP}
USE_KEYCLOAK=${USE_KEYCLOAK}
USE_XRAY=${USE_XRAY}
EOF
}

load_selection() {
  if [[ -f "${STATE_DIR}/selection.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    set -a; source "${STATE_DIR}/selection.env"; set +a
  else
    INSTANCE_COUNT=1
    USE_NGINX=0; USE_NGINX_HTTPS=0
    USE_LDAP=0; USE_KEYCLOAK=0; USE_XRAY=0
  fi
}

# ─── AF auth helper ──────────────────────────────────────────────────────────
# Exchanges admin basic creds for a scoped bearer token. Used by post-up
# configurators that hit /access/api/v1/* endpoints (which require Bearer
# auth as of AF 7.100+).
af_admin_token() {
  local af_url="$1"  # e.g. http://localhost:8082
  local user="${ADMIN_USER:-admin}"
  local pass="${ADMIN_PASS:-${AF_ADMIN_PASSWORD:-password}}"
  curl -sS -u "${user}:${pass}" \
    -X POST -H 'Content-Type: application/json' \
    --data '{"username":"admin","scope":"applied-permissions/admin","expires_in":3600,"refreshable":false}' \
    "${af_url}/access/api/v1/tokens" \
    | jq -r '.access_token'
}

# ─── Health checks ───────────────────────────────────────────────────────────
# Polls AF's /api/system/ping until 200 or timeout (default 10 min, since
# first boot is 5-7 min). The host_port arg should be the AF legacy HTTP
# port (8081 default) — that's where /artifactory/api/system/ping lives.
wait_for_af() {
  local port="$1"
  local label="$2"
  local timeout="${3:-600}"
  local elapsed=0
  local url="http://localhost:${port}/artifactory/api/system/ping"

  log_info "Waiting for ${label} at ${url} ..."
  while (( elapsed < timeout )); do
    if curl -sf -o /dev/null -m 5 "${url}"; then
      log_ok "${label} is healthy."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf '.'
  done
  echo
  log_err "${label} did not become healthy within ${timeout}s."
  return 1
}

# ─── URL summary ─────────────────────────────────────────────────────────────
print_summary() {
  load_selection
  echo
  gum style --border double --padding "1 2" --border-foreground 51 \
    "$(cat <<EOF
arti-deployer is up.

Artifactory 1 UI:  http://localhost:${AF1_HTTP_PORT}/ui/
Artifactory 1 API: http://localhost:${AF1_ROUTER_PORT}/artifactory/
$([[ "${INSTANCE_COUNT}" == "2" ]] && printf "Artifactory 2 UI:  http://localhost:%s/ui/\nArtifactory 2 API: http://localhost:%s/artifactory/\n" "${AF2_HTTP_PORT}" "${AF2_ROUTER_PORT}")
$([[ "${USE_NGINX}" == "1" ]] && printf "NGINX (HTTP):      http://localhost:%s/\n" "${NGINX_HTTP_PORT}")
$([[ "${USE_NGINX_HTTPS}" == "1" ]] && printf "NGINX (HTTPS):     https://localhost:%s/  (self-signed)\n" "${NGINX_HTTPS_PORT}")
$([[ "${USE_KEYCLOAK}" == "1" ]] && printf "Keycloak admin:    http://localhost:%s/  (admin / \$KEYCLOAK_ADMIN_PASSWORD)\n" "${KEYCLOAK_PORT}")
$([[ "${USE_LDAP}" == "1" ]] && printf "LDAP:              ldap://localhost:%s  (cn=admin,dc=jfrog,dc=local / \$LDAP_ADMIN_PASSWORD)\n" "${LDAP_PORT}")
$([[ "${USE_XRAY}" == "1" ]] && printf "Xray UI:           http://localhost:%s/\n" "${XRAY_PORT}")

Default Artifactory admin: admin / password  (forced change on first login)
EOF
)"
}
