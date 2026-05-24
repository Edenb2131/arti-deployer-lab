#!/usr/bin/env bash
# fed-repos.sh — Pre-create one federated repository per common package
# type, ready for testing customer reproductions.
#
# Each repo has both AFs as members, using docker-internal URLs:
#   http://artifactory1:8082/artifactory/<repo>
#   http://artifactory2:8082/artifactory/<repo>
#
# Federation propagates the repo config to the peer automatically once
# created on art1 (CoT must be established first via configure-cot.sh).
#
# Usage:
#   bash scripts/fed-repos.sh             # create all (default)
#   bash scripts/fed-repos.sh create      # same as default
#   bash scripts/fed-repos.sh --delete    # remove all on both AFs
#   bash scripts/fed-repos.sh list        # show which exist on each AF
#
# Naming: {type}-fed
#   generic-fed, docker-fed, maven-fed, npm-fed, pypi-fed,
#   helm-fed, nuget-fed, gradle-fed, composer-fed, go-fed

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

AF1_URL="http://localhost:${AF1_ROUTER_PORT}"
AF2_URL="http://localhost:${AF2_ROUTER_PORT}"
AF1_INTERNAL="http://artifactory1:8082"
AF2_INTERNAL="http://artifactory2:8082"
ADMIN_USER="admin"
ADMIN_PASS="${AF_ADMIN_PASSWORD:-password}"

# Package types we provision. JFrog supports many more; this is the set
# most commonly seen in support tickets. To add a type, append a
# "type:layout" pair below — AF picks a sensible default layout for each
# packageType when omitted, so the layout column is informational only.
REPO_TYPES=(
  "generic"
  "docker"
  "maven"
  "npm"
  "pypi"
  "helm"
  "nuget"
  "gradle"
  "composer"
  "go"
)

# ─── Mode ────────────────────────────────────────────────────────────────────
MODE="create"
case "${1:-create}" in
  create)   MODE="create" ;;
  --delete|delete) MODE="delete" ;;
  list)     MODE="list" ;;
  -h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) log_err "Unknown arg: $1 (expected: create, --delete, list)"; exit 1 ;;
esac

# ─── Verify CoT is in place — otherwise the repos will create but the ───────
# peer member won't accept replication.
if [[ ! -f "${STATE_DIR}/.cot-configured" ]]; then
  log_warn ".cot-configured marker not present — run './arti-deployer up'"
  log_warn "first so CoT and base URLs are set up. Continuing anyway."
fi

# ─── create_repo: PUT one federated repo on art1 ─────────────────────────────
create_repo() {
  local key="$1" pkg="$2"
  local payload code
  payload=$(jq -nc \
    --arg key "${key}" --arg pkg "${pkg}" \
    --arg u1  "${AF1_INTERNAL}/artifactory/${key}" \
    --arg u2  "${AF2_INTERNAL}/artifactory/${key}" \
    '{key:$key, rclass:"federated", packageType:$pkg,
      members:[{url:$u1,enabled:true},{url:$u2,enabled:true}]}')
  code=$(curl -sS -o /tmp/fr-resp.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X PUT -H 'Content-Type: application/json' \
    --data "${payload}" \
    "${AF1_URL}/artifactory/api/repositories/${key}")
  case "${code}" in
    20*) printf '  ✓ %-15s (%s)\n' "${key}" "${pkg}" ;;
    400) if grep -q 'already exists' /tmp/fr-resp.txt; then
           printf '  • %-15s already exists, skipping\n' "${key}"
         else
           printf '  ✗ %-15s HTTP %s: %s\n' "${key}" "${code}" "$(head -c 150 /tmp/fr-resp.txt)"
         fi ;;
    409) printf '  • %-15s already exists, skipping\n' "${key}" ;;
    *)   printf '  ✗ %-15s HTTP %s: %s\n' "${key}" "${code}" "$(head -c 150 /tmp/fr-resp.txt)" ;;
  esac
}

delete_repo() {
  local key="$1" af_url="$2" label="$3"
  local code
  code=$(curl -sS -o /tmp/fr-del.txt -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -X DELETE "${af_url}/artifactory/api/repositories/${key}")
  case "${code}" in
    20*) printf '  ✓ %-15s removed from %s\n' "${key}" "${label}" ;;
    404) printf '  • %-15s not present on %s\n' "${key}" "${label}" ;;
    *)   printf '  ✗ %-15s on %s HTTP %s: %s\n' "${key}" "${label}" "${code}" "$(head -c 150 /tmp/fr-del.txt)" ;;
  esac
}

list_repos() {
  local af_url="$1" label="$2"
  echo "─── ${label} ───"
  for pkg in "${REPO_TYPES[@]}"; do
    local key="${pkg}-fed"
    if curl -sf -o /dev/null -m 5 -u "${ADMIN_USER}:${ADMIN_PASS}" \
         "${af_url}/artifactory/api/repositories/${key}"; then
      printf '  ✓ %-15s present\n' "${key}"
    else
      printf '  - %-15s absent\n' "${key}"
    fi
  done
}

# ─── Dispatch ────────────────────────────────────────────────────────────────
case "${MODE}" in
  create)
    log_step "Creating federated repositories on art1 (will auto-propagate to art2)"
    for pkg in "${REPO_TYPES[@]}"; do
      create_repo "${pkg}-fed" "${pkg}"
    done
    echo
    log_info "Repos are federated between art1 and art2. Push to either, read from both."
    log_info "Replication latency: typically <30 seconds for small files."
    log_info ""
    log_info "Docker push example (replace localhost:8082 with nginx HTTPS if preferred):"
    log_info "  docker pull hello-world"
    log_info "  docker tag hello-world localhost:${AF1_ROUTER_PORT}/docker-fed/hello-world:latest"
    log_info "  docker login localhost:${AF1_ROUTER_PORT} -u admin -p password"
    log_info "  docker push localhost:${AF1_ROUTER_PORT}/docker-fed/hello-world:latest"
    log_info "  docker pull localhost:${AF2_ROUTER_PORT}/docker-fed/hello-world:latest"
    ;;
  delete)
    log_step "Removing federated repos from BOTH AFs"
    for pkg in "${REPO_TYPES[@]}"; do
      delete_repo "${pkg}-fed" "${AF1_URL}" "art1"
      delete_repo "${pkg}-fed" "${AF2_URL}" "art2"
    done
    ;;
  list)
    log_step "Federated repo status"
    list_repos "${AF1_URL}" "art1"
    list_repos "${AF2_URL}" "art2"
    ;;
esac
