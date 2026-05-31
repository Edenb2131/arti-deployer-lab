#!/usr/bin/env bash
# install-extra-cas.sh — Optional: import extra CA certificates into each AF
# container's JVM cacerts. Useful when running behind a TLS-intercepting
# corporate proxy (Zscaler, Netskope, Palo Alto Prisma, ...) whose
# replacement certs aren't trusted by the AF JVM's default truststore.
#
# Symptom this fixes: AF logs show "PKIX path building failed" when remote
# repos try to reach public registries (npmjs.org, pypi.org, ...), and the
# UI Test button on those remotes returns the same error.
#
# Two complementary inputs (both optional, set in .env):
#   EXTRA_TRUSTED_CA_BUNDLE  — absolute path to a local PEM file (one or
#                              more CA certs). Useful when you already have
#                              your corp root CA on disk.
#   EXTRA_CA_PROBE_HOSTS     — space-separated 'host[:port]' list. The
#                              script execs into the AF container, runs
#                              `openssl s_client -showcerts` against each
#                              host (so what we capture is exactly the
#                              chain Zscaler/MITM presents to that
#                              container), and imports all CAs in the
#                              chain. Default port 443. The leaf cert is
#                              skipped — only intermediates and the root
#                              are imported, so cert rotations on the
#                              leaf don't break trust.
#
# If both are unset → no-op.
#
# Idempotent: re-runs wipe prior extra-ca-* aliases and re-import. Imports
# BEFORE the MC-activation restart in `./arti-deployer up`, so no extra
# restart is needed for the new trust to take effect.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
load_env

BUNDLE="${EXTRA_TRUSTED_CA_BUNDLE:-}"
PROBE_HOSTS="${EXTRA_CA_PROBE_HOSTS:-}"

if [[ -z "${BUNDLE}" && -z "${PROBE_HOSTS}" ]]; then
  log_info "EXTRA_TRUSTED_CA_BUNDLE and EXTRA_CA_PROBE_HOSTS unset — skipping extra CA import."
  exit 0
fi

CACERTS="/opt/jfrog/artifactory/app/third-party/java/lib/security/cacerts"
KEYTOOL="/opt/jfrog/artifactory/app/third-party/java/bin/keytool"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
COLLECT_DIR="${TMP}/collected"
mkdir -p "${COLLECT_DIR}"

# ─── Step 1: collect certs from the static bundle (if set) ──────────────────
if [[ -n "${BUNDLE}" ]]; then
  if [[ ! -f "${BUNDLE}" ]]; then
    log_err "EXTRA_TRUSTED_CA_BUNDLE='${BUNDLE}' but no such file."
    exit 1
  fi
  cnt=$(grep -c "BEGIN CERTIFICATE" "${BUNDLE}" 2>/dev/null || echo 0)
  if [[ "${cnt}" == "0" ]]; then
    log_err "${BUNDLE} contains no PEM certificates."
    exit 1
  fi
  log_step "Reading ${cnt} CA(s) from ${BUNDLE}"
  cp "${BUNDLE}" "${TMP}/bundle.pem"
fi

# ─── Step 2: probe each host from inside art1 and collect the chain ─────────
# We probe from inside an AF container so the captured chain is the one Zscaler
# (or any MITM) presents to *that* container, which may differ from what your
# Mac sees.
PROBE_SOURCE_CONTAINER=""
for c in artifactory1 artifactory2; do
  if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    PROBE_SOURCE_CONTAINER="${c}"
    break
  fi
done

if [[ -n "${PROBE_HOSTS}" ]]; then
  if [[ -z "${PROBE_SOURCE_CONTAINER}" ]]; then
    log_warn "EXTRA_CA_PROBE_HOSTS set but no AF container is running yet — skipping probe."
  else
    log_step "Probing ${PROBE_HOSTS} from inside ${PROBE_SOURCE_CONTAINER}"
    for entry in ${PROBE_HOSTS}; do
      host="${entry%%:*}"
      port="${entry##*:}"
      [[ "${port}" == "${entry}" ]] && port=443
      probe_out="${TMP}/probe-${host}-${port}.pem"
      docker exec "${PROBE_SOURCE_CONTAINER}" sh -c "
        echo | openssl s_client -showcerts -servername '${host}' -connect '${host}:${port}' 2>/dev/null \
          | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/'
      " > "${probe_out}" 2>/dev/null || true
      chain_count=$(grep -c "BEGIN CERTIFICATE" "${probe_out}" 2>/dev/null || echo 0)
      if [[ "${chain_count}" == "0" ]]; then
        log_warn "  ${host}:${port} — no chain returned (host unreachable from container?)"
        continue
      fi
      log_info "  ${host}:${port} — ${chain_count} cert(s) in chain (leaf will be skipped)"
    done
  fi
fi

# ─── Step 3: collect every cert into individual files, skipping leaf certs ──
# (leaf = cert #1 in a probe chain; bundle certs are assumed all CAs).
python3 - "${TMP}" "${COLLECT_DIR}" <<'PY'
import os, sys, glob, hashlib, re, subprocess

tmp_dir, out_dir = sys.argv[1], sys.argv[2]
seen = set()
out_idx = 0

def fingerprint(pem_bytes: bytes) -> str:
    # SHA-256 of the DER-encoded cert. We shell out to openssl for portability.
    p = subprocess.run(
        ["openssl", "x509", "-noout", "-fingerprint", "-sha256"],
        input=pem_bytes, capture_output=True
    )
    line = p.stdout.decode(errors="ignore").strip()
    return line.split("=", 1)[-1] if "=" in line else line

def emit(pem_text: str):
    global out_idx
    pem_bytes = (pem_text + "\n").encode()
    fp = fingerprint(pem_bytes)
    if not fp or fp in seen:
        return
    seen.add(fp)
    out_idx += 1
    with open(os.path.join(out_dir, f"cert-{out_idx:03d}.pem"), "wb") as f:
        f.write(pem_bytes)

def parts(path: str):
    with open(path) as f: data = f.read()
    return [p.strip() + "\n-----END CERTIFICATE-----"
            for p in data.split("-----END CERTIFICATE-----") if "BEGIN" in p]

# Bundle: all certs are CAs (caller's responsibility), include all.
b = os.path.join(tmp_dir, "bundle.pem")
if os.path.exists(b):
    for c in parts(b):
        emit(c)

# Probes: first cert in each chain is the leaf, skip it.
for probe in sorted(glob.glob(os.path.join(tmp_dir, "probe-*.pem"))):
    chain = parts(probe)
    for c in chain[1:]:  # skip leaf
        emit(c)

print(f"COLLECTED={out_idx}")
PY

COLLECTED=$(ls "${COLLECT_DIR}"/cert-*.pem 2>/dev/null | wc -l | tr -d ' ')
if [[ "${COLLECTED}" == "0" ]]; then
  log_warn "No certs to import after dedup. Nothing to do."
  exit 0
fi
log_step "Importing ${COLLECTED} unique CA(s) into AF JVM cacerts"

# ─── Step 4: install into each running AF container ─────────────────────────
install_into_container() {
  local container="$1"
  log_info "  ${container}: wiping prior extra-ca-* aliases, importing ${COLLECTED} cert(s)..."
  docker exec --user root "${container}" sh -c "
    for a in \$(${KEYTOOL} -list -keystore ${CACERTS} -storepass changeit 2>/dev/null \
                | awk -F, '/^extra-ca-/ {print \$1}'); do
      ${KEYTOOL} -delete -alias \"\$a\" -keystore ${CACERTS} -storepass changeit 2>/dev/null || true
    done
  "
  local i=0
  for pem in "${COLLECT_DIR}"/cert-*.pem; do
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
