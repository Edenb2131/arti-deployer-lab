#!/usr/bin/env bash
# install-extra-cas.sh — Optional: import an extra CA bundle into each AF
# container's JVM cacerts. Useful when running behind a TLS-intercepting
# corporate proxy (Zscaler, Netskope, Palo Alto Prisma, ...) whose
# replacement certs aren't trusted by the AF JVM's default truststore.
#
# Symptom this fixes: AF logs show "PKIX path building failed" when remote
# repos try to reach public registries (npmjs.org, pypi.org, ...), and the
# UI Test button on those remotes returns the same error.
#
# Configuration: set EXTRA_TRUSTED_CA_BUNDLE in .env to the absolute path
# of a PEM file containing one or more CA certificates. Leave empty for the
# default (no-op). The PEM bytes never enter git — your bundle stays on
# your disk; this script only references it.
#
# Idempotent: re-runs wipe prior extra-ca-* aliases and re-import. Imports
# BEFORE the MC-activation restart in `./arti-deployer up`, so no extra
# restart is needed for the new trust to take effect.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

BUNDLE="${EXTRA_TRUSTED_CA_BUNDLE:-}"
if [[ -z "${BUNDLE}" ]]; then
  log_info "EXTRA_TRUSTED_CA_BUNDLE unset — skipping extra CA import."
  exit 0
fi

if [[ ! -f "${BUNDLE}" ]]; then
  log_err "EXTRA_TRUSTED_CA_BUNDLE='${BUNDLE}' but no such file."
  exit 1
fi

CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${BUNDLE}" 2>/dev/null || echo 0)
if [[ "${CERT_COUNT}" == "0" ]]; then
  log_err "${BUNDLE} contains no PEM certificates."
  exit 1
fi

log_step "Importing ${CERT_COUNT} CA(s) from ${BUNDLE} into AF JVM cacerts"

# Split bundle into individual certs — some keytool versions only import the
# first cert from a multi-cert PEM. Python is more portable than awk across
# macOS / Linux.
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
python3 - "${BUNDLE}" "${TMP}" <<'PY'
import sys, os
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f: data = f.read()
parts = [p.strip() for p in data.split('-----END CERTIFICATE-----') if 'BEGIN' in p]
for i, p in enumerate(parts, 1):
    with open(os.path.join(dst, f'cert-{i}.pem'), 'w') as out:
        out.write(p + '\n-----END CERTIFICATE-----\n')
PY

CACERTS="/opt/jfrog/artifactory/app/third-party/java/lib/security/cacerts"
KEYTOOL="/opt/jfrog/artifactory/app/third-party/java/bin/keytool"

install_into_container() {
  local container="$1"
  log_info "  ${container}: wiping prior extra-ca-* aliases, importing ${CERT_COUNT} cert(s)..."
  # Idempotency: remove any aliases this script previously installed.
  docker exec --user root "${container}" sh -c "
    for a in \$(${KEYTOOL} -list -keystore ${CACERTS} -storepass changeit 2>/dev/null \
                | awk -F, '/^extra-ca-/ {print \$1}'); do
      ${KEYTOOL} -delete -alias \"\$a\" -keystore ${CACERTS} -storepass changeit 2>/dev/null || true
    done
  "
  local i=0
  for pem in "${TMP}"/cert-*.pem; do
    i=$((i+1))
    docker cp "${pem}" "${container}:/tmp/extra-ca-${i}.pem" >/dev/null
    docker exec --user root "${container}" sh -c "
      ${KEYTOOL} -import -trustcacerts -noprompt \
        -alias extra-ca-${i} -file /tmp/extra-ca-${i}.pem \
        -keystore ${CACERTS} -storepass changeit >/dev/null 2>&1
      rm -f /tmp/extra-ca-${i}.pem
    "
  done
}

for c in artifactory1 artifactory2; do
  if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    install_into_container "${c}"
  fi
done

log_ok "Extra CAs imported. The next AF restart (already part of \`up\`) will pick them up."
