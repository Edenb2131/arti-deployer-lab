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

? Add NGINX reverse proxy?            (y/N)
?   Use HTTPS for NGINX?              (y/N)   [only if NGINX = y]
? Add LDAP server?                    (y/N)
? Use AF_VERSION 7.111.9?             (y/N)
? License for AF#1: paste / file / keep / clear
```

## What's in v1

| Feature | Status | Doc |
|---|---|---|
| Single AF + Postgres | ✅ wired end-to-end | [docs/single-instance.md](docs/single-instance.md) |
| Two AF + auto CoT + Access Federation | ✅ wired (best-effort REST bootstrap) | [docs/cot-federation.md](docs/cot-federation.md) |
| NGINX (HTTP or HTTPS) | ✅ wired end-to-end | [docs/nginx.md](docs/nginx.md) |
| LDAP (OpenLDAP) | ✅ wired end-to-end (osixia/openldap, dc=example,dc=org) | [docs/ldap.md](docs/ldap.md) |

QA'd across all 12 active combinations of `{1, 2 instances} × {no-nginx, http,
https} × {0,1 LDAP}` — all pass.

## Requirements

- Docker Desktop (or Colima) with at least 4 CPU / 8 GB RAM allocated
- [`gum`](https://github.com/charmbracelet/gum) — `brew install gum`
- `gettext` for `envsubst` — `brew install gettext`
- `jq`, `curl`, `openssl` — usually pre-installed on macOS
- A JFrog Artifactory license (Pro / Enterprise / EnterpriseX)

## Quick start

```bash
git clone https://github.com/Edenb2131/arti-deployer-lab.git
cd arti-deployer-lab
./arti-deployer init       # bootstraps .env with auto-generated secrets
# Either edit .env and paste ARTIFACTORY_LICENSE, OR let the wizard
# prompt you for it on the next step.
./arti-deployer            # interactive wizard
```

## Commands

```bash
./arti-deployer init              # bootstrap .env with fresh secrets
./arti-deployer                   # interactive wizard (same as `up`)
./arti-deployer up                # interactive wizard
./arti-deployer up [flags]        # non-interactive — see flags below
./arti-deployer down              # stop everything (keeps volumes)
./arti-deployer reset             # stop + wipe volumes (destructive)
./arti-deployer cleanup [--all]   # full wipe: containers, volumes, networks,
                                  # rendered configs, state. --all also wipes
                                  # .env and .licenses/.
./arti-deployer status            # show running services
./arti-deployer logs [service]    # tail logs
```

### Non-interactive flags (`up`)

```bash
./arti-deployer up --instances 2 --https --ldap --yes
```

- `--instances {1|2}` — number of AF instances (2 enables CoT)
- `--nginx` / `--https` — NGINX in front, optionally with self-signed HTTPS
- `--ldap` — add the LDAP overlay
- `--yes` — skip the final "Proceed?" confirmation

## Layout

```
arti-deployer-lab/
├── arti-deployer         # main entrypoint
├── deploy-artifacts.py   # add-on: populate the lab with artifacts (see docs/deploy-artifacts.md)
├── compose/              # one compose file per topology / overlay
├── config/               # per-service config (system.yaml.tmpl, nginx.conf, etc.)
├── scripts/              # post-startup configurators (CoT, LDAP) + helpers
├── docs/                 # one .md per feature
├── requirements.txt      # python deps for deploy-artifacts.py
└── .env.example
```

### Populate with artifacts (optional add-on)

After `up`, you can spin up a populated environment (real packages
pulled through real repos, JFrog Builds recorded) with:

```bash
pip install -r requirements.txt
./deploy-artifacts.py             # docker + npm + pypi against art1
```

See [docs/deploy-artifacts.md](docs/deploy-artifacts.md) for all options.

## Safety notes

- `./arti-deployer init` writes `.env` with `openssl rand`-generated values.
  Never commit `.env` (it's gitignored).
- Pasted licenses land in `.licenses/` (chmod 600, gitignored).
- The default self-signed certs are for local testing only.
- Customer data should never enter this repo. Use anonymized fixtures.

## Contributing

PRs welcome. See [docs/extending.md](docs/extending.md) for how to add a new
overlay (e.g., SAML, MinIO/S3 filestore, replication).
