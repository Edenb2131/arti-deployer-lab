# Architecture

## Layered compose model

```
            ┌─────────────────────────────────────────┐
            │   arti-deployer (bash + gum TUI)        │
            │   - reads .env                          │
            │   - asks: instances, overlays, HTTPS    │
            │   - builds compose -f chain             │
            │   - runs post-up configurators          │
            └────────────────┬────────────────────────┘
                             │
                             ▼ docker compose -f … -f … up -d
            ┌──────────────────────────────────────────────────┐
            │ Base topology (always)                           │
            │  • compose/art1.yml  → artifactory1 + postgres-art1│
            └─────┬────────────────────────────────────────────┘
                  │ optional layers (chosen in wizard)
                  ├── compose/art2.yml         → artifactory2 + postgres-art2
                  ├── compose/nginx.yml        OR  compose/nginx-https.yml
                  └── compose/ldap.yml         → arti-openldap
                  │
                  ▼ post-up configurators (each behind a .arti-deployer/.*-configured marker)
                  ├── scripts/configure-cot.sh        (if instances == 2)
                  └── scripts/configure-ldap.sh       (if LDAP)
```

Everything sits on one shared docker bridge network — `arti-deployer_net` —
defined as non-external in `art1.yml` and referenced as external in all
overlays.

## Why one base + many overlays (not one big compose)

- Each piece reads independently.
- Mixing combinations is trivial — add a `-f` flag.
- Adding a new overlay is purely additive — no editing of an ever-growing
  master file, no merge conflicts.
- Each overlay's failure modes are isolated and documented next to that
  overlay's compose file.

The CLI hides the `-f` chaining behind the wizard, but you can always
invoke `docker compose -f compose/art1.yml -f compose/ldap.yml up`
directly if you want a non-standard combination.

## State persistence

- `.env` — user-edited, gitignored. Holds license + ports + dev passwords.
- `.arti-deployer/selection.env` — last wizard choice, used by `down`,
  `logs`, `status` to target the right compose files.
- `.arti-deployer/.*-configured` — idempotency markers for post-up scripts.
- Named docker volumes (prefix `arti-deployer_`) — survive `down`, wiped by
  `reset`.

## Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Compose file | `compose/<overlay>.yml` | `compose/ldap.yml` |
| Per-service config | `config/<overlay>/<file>` | `config/ldap/ldifs/users.ldif` |
| Configurator script | `scripts/configure-<overlay>.sh` | `scripts/configure-ldap.sh` |
| Doc | `docs/<overlay>.md` | `docs/nginx.md` |
| Marker | `.arti-deployer/.<overlay>-configured` | `.arti-deployer/.cot-configured` |
| Container | `arti-<name>` for overlays; `<base>` for primary | `arti-openldap`, `artifactory1` |
| Volume | `arti-deployer_<service>-data` | `arti-deployer_openldap-data` |
| Network alias | container name | `openldap`, `artifactory1` |

Following these is what makes a new overlay drop-in.
