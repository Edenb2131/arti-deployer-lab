# Adding a new overlay

The layered model is designed so adding a new piece is purely additive.
Here's the playbook, with a SAML-via-SimpleSAMLphp overlay as the worked
example.

## The five files

For an overlay called `saml`, you create exactly five things:

```
compose/saml.yml                  ← the docker-compose definition
config/saml/...                   ← any static config (LDIFs, realms, certs…)
scripts/configure-saml.sh         ← post-startup wiring into AF (if needed)
docs/saml.md                      ← what it does, gotchas, manual fallback
```

…and a tiny edit:

```
arti-deployer + scripts/lib.sh    ← add USE_SAML flag + chain entry
```

## Step-by-step

### 1. Write `compose/saml.yml`

Follow the existing overlays — explicit `name:` on the network as
`arti-deployer_net` with `external: true`, named volumes prefixed
`arti-deployer_`, and a `healthcheck`. Example skeleton:

```yaml
services:
  simplesamlphp:
    image: kristophjunge/test-saml-idp:latest
    container_name: arti-saml-idp
    restart: unless-stopped
    environment:
      SIMPLESAMLPHP_SP_ENTITY_ID: artifactory
      SIMPLESAMLPHP_SP_ASSERTION_CONSUMER_SERVICE: http://localhost:8081/artifactory/api/saml/loginResponse
    ports:
      - "8088:8080"
    networks: [arti-net]

networks:
  arti-net:
    name: arti-deployer_net
    external: true
```

### 2. Add wizard plumbing

In `arti-deployer`, the `wizard()` function — add `SAML` to the multi-select:

```bash
configs=$(gum choose --no-limit ... \
  "NGINX (reverse proxy)" \
  "LDAP" \
  "Keycloak (OIDC)" \
  "SAML (SimpleSAMLphp)" || true)

USE_SAML=0
grep -q "SAML" <<< "${configs}" && USE_SAML=1
```

Then in `scripts/lib.sh` `build_compose_chain()`:

```bash
[[ "${USE_SAML}" == "1" ]] && chain+=("-f" "${COMPOSE_DIR}/saml.yml")
```

…and add `USE_SAML` to `save_selection` / `load_selection`.

### 3. Write `scripts/configure-saml.sh` (if integration needs API calls)

Use `lib.sh` for `log_info` / `af_curl`. Always:
- Use a `.arti-deployer/.<overlay>-configured` marker to be idempotent.
- Use **internal** docker hostnames (`http://artifactory1:8082`) when AF
  must reach the service, and **host** URLs when the browser must reach it.
- `set -euo pipefail` and `fail_soft` on optional steps so a partial failure
  doesn't break the rest of the bring-up.

### 4. Hook into `arti-deployer` `cmd_up`

```bash
if [[ "${USE_SAML}" == "1" ]]; then
  log_step "Wiring SAML into Artifactory"
  "${SCRIPTS_DIR}/configure-saml.sh" || log_warn "SAML configurator returned non-zero"
fi
```

### 5. Write `docs/saml.md`

Mirror the structure of existing overlay docs:
- Status (wired / scaffold)
- What runs (containers, ports)
- How AF gets wired
- Manual fallback (UI clicks)
- Troubleshooting

…and add the link to `README.md`'s status table.

## Ideas for future overlays

| Overlay | Why it matters for support |
|---|---|
| **SAML** (SimpleSAMLphp) | Many enterprise customers; complements Keycloak |
| **Active Directory** (samba) | AD-specific group sync quirks that plain LDAP doesn't have |
| **MinIO S3 filestore** | Filestore migration / latency tickets |
| **MySQL / MSSQL / Oracle DB** | DB-specific schema issues — swap Postgres for one of these |
| **Replication** | Push/pull replication between art1 and art2 (separate from federation) |
| **HA cluster** | 3-node AF sharing one Postgres + shared filestore (NFS) |
| **toxiproxy** | Simulated network latency / drops for flaky-customer-network repros |
| **MailHog** | Email notification testing |
| **Prometheus + Grafana** | Metrics endpoint exploration |

Pick one and PR it.
