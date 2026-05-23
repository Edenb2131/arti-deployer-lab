#!/usr/bin/env bash
# gen-self-signed.sh — Generate a self-signed cert for NGINX HTTPS.
# Idempotent: re-uses an existing cert if one is already present.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CERTS_DIR="${CONFIG_DIR}/nginx/certs"
mkdir -p "${CERTS_DIR}"

if [[ -f "${CERTS_DIR}/server.crt" && -f "${CERTS_DIR}/server.key" ]]; then
  log_info "Self-signed cert already exists at ${CERTS_DIR}/. Reusing."
  exit 0
fi

log_info "Generating self-signed cert (valid 365 days) for localhost + arti containers..."

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "${CERTS_DIR}/server.key" \
  -out    "${CERTS_DIR}/server.crt" \
  -subj   "/C=US/ST=Lab/L=Local/O=arti-deployer/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:artifactory1,DNS:artifactory2,IP:127.0.0.1" \
  >/dev/null 2>&1

chmod 600 "${CERTS_DIR}/server.key"
chmod 644 "${CERTS_DIR}/server.crt"

log_ok "Self-signed cert written to ${CERTS_DIR}/server.{crt,key}"
log_warn "Browsers will warn — this cert is for local testing only."
