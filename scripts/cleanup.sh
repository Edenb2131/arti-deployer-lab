#!/usr/bin/env bash
# cleanup.sh — Tear down EVERYTHING this lab created and prove it.
#
# What gets removed:
#   - All compose-managed containers (artifactory, postgres, nginx, ldap,
#     keycloak services), via `docker compose down -v --remove-orphans`
#     to release file handles cleanly, then forced removal as a safety net
#   - All named volumes (arti-deployer_*)
#   - The shared docker network (arti-deployer_net)
#   - Any anonymous volumes attached to lab containers
#   - Rendered configs (config/**/{system.yaml,realm.json,*.ldif})
#   - Generated cert files (config/nginx/certs/server.*)
#   - Generated license drop-ins (config/art{1,2}/artifactory.lic)
#   - State markers (.arti-deployer/, including all *.configured flags)
#
# Preserved by default (user input):
#   - .env             (your config + secrets)
#   - .licenses/       (licenses you pasted into the wizard)
#
# At the end: a verification pass asserts that NOTHING related to the lab
# remains. Exits non-zero (and prints what's left) if anything dangling.
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
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) log_err "Unknown flag: ${arg}"; exit 1 ;;
  esac
done

# ─── Plan ────────────────────────────────────────────────────────────────────
# macOS bash 3.2 has no mapfile — read with a while loop for portability.
CONTAINERS=()
while IFS= read -r line; do [[ -n "$line" ]] && CONTAINERS+=("$line"); done < <(
  docker ps -aq --filter 'name=artifactory1' --filter 'name=artifactory2' \
                --filter 'name=postgres-art1' --filter 'name=postgres-art2' \
                --filter 'name=arti-nginx' --filter 'name=arti-openldap' \
                --filter 'name=arti-keycloak' \
    2>/dev/null
)
VOLUMES=()
while IFS= read -r line; do [[ -n "$line" ]] && VOLUMES+=("$line"); done \
  < <(docker volume ls -q  --filter 'name=arti-deployer_' 2>/dev/null)
NETWORKS=()
while IFS= read -r line; do [[ -n "$line" ]] && NETWORKS+=("$line"); done \
  < <(docker network ls -q --filter 'name=arti-deployer_' 2>/dev/null)

# ─── Show plan + confirm ─────────────────────────────────────────────────────
log_step "Cleanup plan"
echo "Containers (${#CONTAINERS[@]}):"
if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  for id in "${CONTAINERS[@]}"; do
    docker ps -a --format '  - {{.Names}} ({{.Status}})' --filter "id=${id}" 2>/dev/null
  done
fi
echo "Named volumes (${#VOLUMES[@]}):"
for v in "${VOLUMES[@]}"; do echo "  - ${v}"; done
echo "Networks (${#NETWORKS[@]}):"
for n in "${NETWORKS[@]}"; do
  docker network inspect "${n}" --format '  - {{.Name}}' 2>/dev/null || echo "  - ${n}"
done

FILE_PATTERNS=(
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
# Phase 1: bring the compose stack down cleanly. This handles file handles
# and ensures docker compose's own bookkeeping is clear. -v wipes anonymous
# volumes, --remove-orphans catches anything detached.
log_step "docker compose down -v --remove-orphans"
cd "${ROOT_DIR}"
COMPOSE_FILES=( -f compose/art1.yml -f compose/art2.yml -f compose/nginx.yml \
                -f compose/nginx-https.yml -f compose/ldap.yml -f compose/keycloak.yml )
docker compose --env-file .env "${COMPOSE_FILES[@]}" down -v --remove-orphans 2>&1 \
  | sed 's/^/  /' || true

# Phase 2: belt-and-suspenders forced removal for anything compose missed.
log_step "Force-removing any straggler containers"
if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
  docker rm -f "${CONTAINERS[@]}" 2>/dev/null | sed 's/^/  /' || true
fi

log_step "Removing named volumes"
if [[ ${#VOLUMES[@]} -gt 0 ]]; then
  docker volume rm "${VOLUMES[@]}" 2>/dev/null | sed 's/^/  /' || true
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

# ─── Verification — prove the state is clean ────────────────────────────────
log_step "Verifying clean state"
leftover=0

c_left=$(docker ps -aq --filter 'name=artifactory1' --filter 'name=artifactory2' \
            --filter 'name=postgres-art1' --filter 'name=postgres-art2' \
            --filter 'name=arti-nginx' --filter 'name=arti-openldap' \
            --filter 'name=arti-keycloak' 2>/dev/null | wc -l | tr -d ' ')
v_left=$(docker volume ls -q --filter 'name=arti-deployer_' 2>/dev/null | wc -l | tr -d ' ')
n_left=$(docker network ls -q --filter 'name=arti-deployer_' 2>/dev/null | wc -l | tr -d ' ')

echo "  containers remaining: ${c_left}"
echo "  volumes  remaining:   ${v_left}"
echo "  networks remaining:   ${n_left}"

if [[ "${c_left}" != "0" || "${v_left}" != "0" || "${n_left}" != "0" ]]; then
  leftover=1
  log_err "Some docker resources survived cleanup:"
  docker ps -a    --filter 'name=artifactory1' --filter 'name=artifactory2' \
                  --filter 'name=postgres-art1' --filter 'name=postgres-art2' \
                  --filter 'name=arti-nginx'   --filter 'name=arti-openldap' \
                  --filter 'name=arti-keycloak' --format '    container: {{.Names}} ({{.Status}})' 2>/dev/null
  docker volume ls --filter 'name=arti-deployer_' --format '    volume: {{.Name}}' 2>/dev/null
  docker network ls --filter 'name=arti-deployer_' --format '    network: {{.Name}}' 2>/dev/null
fi

f_left=0
for p in "${FILE_PATTERNS[@]}"; do
  for actual in $p; do
    if [[ -e "${actual}" ]]; then
      log_err "  file/dir survived: ${actual}"
      f_left=$((f_left + 1))
      leftover=1
    fi
  done
done
echo "  rendered files remaining: ${f_left}"

if [[ "${leftover}" == "1" ]]; then
  log_err "Cleanup INCOMPLETE — see survivors above."
  exit 1
fi

log_ok "Verified clean: 0 containers, 0 volumes, 0 networks, 0 rendered files."
if [[ "${WIPE_ALL}" == "1" ]]; then
  log_info "Run './arti-deployer init' to bootstrap a fresh .env, then './arti-deployer up'."
else
  log_info "Run './arti-deployer up' to redeploy from scratch."
fi
