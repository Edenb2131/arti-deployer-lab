# arti-deployer-lab

A Docker-Compose toolkit for **Artifactory Support engineers** to spin up
realistic customer-like environments locally for issue reproduction.

> Built for the JFrog App Support team. PostgreSQL everywhere by default.

```text
$ ./arti-deployer

┌─ How many Artifactory instances? ──────────────────┐
│ > 1                                                │
│   2  (auto-configures CoT + Access Federation)     │
└────────────────────────────────────────────────────┘

? Pick configurations (space to toggle, enter to confirm):
  [x] NGINX (reverse proxy)
  [ ] LDAP
  [x] Keycloak (OIDC)

? Use HTTPS for NGINX? (y/N)
? Deploy Xray as well?    (y/N)
```

## What's in v1

| Feature | Status | Doc |
|---|---|---|
| Single AF + Postgres | ✅ wired end-to-end | [docs/single-instance.md](docs/single-instance.md) |
| Two AF + auto CoT + Access Federation | ✅ wired (best-effort REST bootstrap) | [docs/cot-federation.md](docs/cot-federation.md) |
| NGINX (HTTP or HTTPS) | ✅ wired end-to-end | [docs/nginx.md](docs/nginx.md) |
| LDAP (OpenLDAP) | ⚠️ scaffold — drop in `ldapsetupforartifactory` LDIFs | [docs/ldap.md](docs/ldap.md) |
| Keycloak (OIDC) | ⚠️ scaffold — realm pre-imported, AF wiring is manual | [docs/keycloak.md](docs/keycloak.md) |
| Xray | ⚠️ scaffold — minimal compose, license needed | [docs/xray.md](docs/xray.md) |

## Requirements

- Docker Desktop (or Colima) with at least 8 CPU / 12 GB RAM allocated
- [`gum`](https://github.com/charmbracelet/gum) — `brew install gum`
- `jq`, `curl`, `openssl` — usually pre-installed on macOS
- A JFrog Artifactory license (Pro / Enterprise / EnterpriseX)

## Quick start

```bash
git clone https://github.com/Edenb2131/arti-deployer-lab.git
cd arti-deployer-lab
cp .env.example .env
# edit .env and paste ARTIFACTORY_LICENSE
./arti-deployer            # interactive wizard
```

## Commands

```bash
./arti-deployer            # interactive wizard (same as `up`)
./arti-deployer up         # interactive wizard
./arti-deployer down       # stop everything (keeps volumes)
./arti-deployer reset      # stop everything + wipe volumes (destructive)
./arti-deployer status     # show what's running
./arti-deployer logs [svc] # tail logs (default: all)
```

## Layout

```
arti-deployer-lab/
├── arti-deployer         # main entrypoint
├── compose/              # one compose file per topology / overlay
├── config/               # per-service config (system.yaml, nginx.conf, etc.)
├── scripts/              # post-startup configurators (CoT, LDAP, etc.)
├── docs/                 # one .md per feature
└── .env.example
```

## Safety notes

- All passwords in `.env.example` are dev-only placeholders. **Do not** point
  this at a production license server or reuse passwords elsewhere.
- The default self-signed certs are for local testing only.
- Customer data should never enter this repo. Use anonymized fixtures.

## Contributing

PRs welcome. See [docs/extending.md](docs/extending.md) for how to add a new
overlay (e.g., SAML, MinIO/S3 filestore, replication).
