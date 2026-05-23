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
  for bin in docker gum jq curl openssl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker-compose-v2")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing dependencies: ${missing[*]}"
    cat >&2 <<EOF

Install on macOS with Homebrew:
  brew install gum jq

Docker Desktop (or Colima) must be running and provide 'docker compose'.

EOF
    exit 1
  fi
}

# ─── Env loading ─────────────────────────────────────────────────────────────
load_env() {
  if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    log_warn ".env not found. Copying from .env.example..."
    cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
    log_info "Edit ${ROOT_DIR}/.env to set ARTIFACTORY_LICENSE, then re-run."
    exit 1
  fi
  # shellcheck disable=SC1090,SC1091
  set -a; source "${ROOT_DIR}/.env"; set +a
}

# ─── License handling ────────────────────────────────────────────────────────
# Writes config/<instance>/artifactory.lic from .env. Errors if no license set.
write_license() {
  local instance="$1"  # art1 or art2
  local dest="${CONFIG_DIR}/${instance}/artifactory.lic"

  if [[ -n "${ARTIFACTORY_LICENSE_FILE:-}" ]]; then
    if [[ ! -f "${ARTIFACTORY_LICENSE_FILE}" ]]; then
      log_err "ARTIFACTORY_LICENSE_FILE is set but file not found: ${ARTIFACTORY_LICENSE_FILE}"
      exit 1
    fi
    cp "${ARTIFACTORY_LICENSE_FILE}" "${dest}"
  elif [[ -n "${ARTIFACTORY_LICENSE:-}" ]]; then
    printf '%b\n' "${ARTIFACTORY_LICENSE}" > "${dest}"
  else
    log_err "No Artifactory license configured. Set ARTIFACTORY_LICENSE or ARTIFACTORY_LICENSE_FILE in .env."
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

# ─── Health checks ───────────────────────────────────────────────────────────
# Polls AF router health endpoint until 200 or timeout (default 5 min).
wait_for_af() {
  local port="$1"
  local label="$2"
  local timeout="${3:-300}"
  local elapsed=0
  local url="http://localhost:${port}/router/api/v1/system/health"

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
