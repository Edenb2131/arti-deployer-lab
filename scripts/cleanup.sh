#!/usr/bin/env bash
# cleanup.sh — Tear down EVERYTHING this lab created.
#
# What gets removed:
#   - All compose-managed containers (artifactory, postgres, nginx, ldap,
#     keycloak services)
#   - All named volumes (arti-deployer_*)
#   - The shared docker network (arti-deployer_net)
#   - Rendered configs (config/**/{system.yaml,realm.json,*.ldif})
#   - Generated cert files (config/nginx/certs/server.*)
#   - Generated license drop-ins (config/art{1,2}/artifactory.lic)
#   - State markers (.arti-deployer/)
#
# Preserved by default (user input):
#   - .env             (your config + secrets)
#   - .licenses/       (licenses you pasted into the wizard)
#
# Flags:
#   --all      Also remove .env and .licenses/ (full reset to fresh-clone)
#   --force    Skip confirmation prompts
#   --dry-run  Show what would be removed, don't remove

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WIPE_ALL=0
FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --all)     WIPE_ALL=1 ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) log_err "Unknown flag: ${arg}"; exit 1 ;;
  esac
done

# ─── Plan ────────────────────────────────────────────────────────────────────
declare -a CONTAINERS VOLUMES NETWORKS

mapfile -t CONTAINERS < <(
  docker ps -aq --filter 'name=artifactory1' --filter 'name=artifactory2' \
                --filter 'name=postgres-art1' --filter 'name=postgres-art2' \
                --filter 'name=arti-nginx' --filter 'name=arti-openldap' \
                --filter 'name=arti-keycloak' \
    2>/dev/null
)
mapfile -t VOLUMES  < <(docker volume ls -q  --filter 'name=arti-deployer_' 2>/dev/null)
mapfile -t NETWORKS < <(docker network ls -q --filter 'name=arti-deployer_' 2>/dev/null)

# ─── Show plan + confirm ─────────────────────────────────────────────────────
log_step "Cleanup plan"
echo "Containers (${#CONTAINERS[@]}):"
if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  docker ps -a --format '  - {{.Names}} ({{.Status}})' --filter "id=$(IFS=, ; echo "${CONTAINERS[*]}")" 2>/dev/null || \
    for id in "${CONTAINERS[@]}"; do echo "  - ${id}"; done
fi
echo "Named volumes (${#VOLUMES[@]}):"
for v in "${VOLUMES[@]}"; do echo "  - ${v}"; done
echo "Networks (${#NETWORKS[@]}):"
for n in "${NETWORKS[@]}"; do
  docker network inspect "${n}" --format '  - {{.Name}}' 2>/dev/null || echo "  - ${n}"
done

declare -a FILE_PATTERNS=(
  "${CONFIG_DIR}/art1/system.yaml"
  "${CONFIG_DIR}/art2/system.yaml"
  "${CONFIG_DIR}/keycloak/realm.json"
  "${CONFIG_DIR}/ldap/ldifs/*.ldif"
  "${CONFIG_DIR}/nginx/certs/server.crt"
  "${CONFIG_DIR}/nginx/certs/server.key"
  "${CONFIG_DIR}/art1/artifactory.lic"
  "${CONFIG_DIR}/art2/artifactory.lic"
  "${ROOT_DIR}/.arti-deployer"
)
echo "Files / dirs to remove:"
for p in "${FILE_PATTERNS[@]}"; do
  for actual in $p; do
    [[ -e "${actual}" ]] && echo "  - ${actual}"
  done
done

if [[ "${WIPE_ALL}" == "1" ]]; then
  echo "Also (because --all):"
  [[ -f "${ROOT_DIR}/.env"        ]] && echo "  - ${ROOT_DIR}/.env"
  [[ -d "${ROOT_DIR}/.licenses"   ]] && echo "  - ${ROOT_DIR}/.licenses/"
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "Dry run — nothing was removed."
  exit 0
fi

if [[ "${FORCE}" != "1" ]]; then
  echo
  if ! gum confirm "Proceed with cleanup?"; then
    log_warn "Cancelled."
    exit 0
  fi
fi

# ─── Execute ─────────────────────────────────────────────────────────────────
log_step "Removing containers"
if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  docker rm -f "${CONTAINERS[@]}" 2>/dev/null | sed 's/^/  /'
fi

log_step "Removing named volumes"
if [[ ${#VOLUMES[@]} -gt 0 ]]; then
  docker volume rm "${VOLUMES[@]}" 2>/dev/null | sed 's/^/  /'
fi

log_step "Removing networks"
if [[ ${#NETWORKS[@]} -gt 0 ]]; then
  docker network rm "${NETWORKS[@]}" 2>/dev/null | sed 's/^/  /' || true
fi

log_step "Removing rendered configs + state"
for p in "${FILE_PATTERNS[@]}"; do
  for actual in $p; do
    [[ -e "${actual}" ]] && rm -rf "${actual}" && echo "  - removed ${actual}"
  done
done

if [[ "${WIPE_ALL}" == "1" ]]; then
  log_step "Removing .env + .licenses (--all)"
  [[ -f "${ROOT_DIR}/.env"      ]] && rm -f  "${ROOT_DIR}/.env"      && echo "  - removed .env"
  [[ -d "${ROOT_DIR}/.licenses" ]] && rm -rf "${ROOT_DIR}/.licenses" && echo "  - removed .licenses/"
fi

log_ok "Cleanup complete."
if [[ "${WIPE_ALL}" == "1" ]]; then
  log_info "Run './arti-deployer init' to bootstrap a fresh .env, then './arti-deployer up'."
else
  log_info "Run './arti-deployer up' to redeploy."
fi
