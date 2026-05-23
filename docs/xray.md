# Xray overlay

Adds a JFrog Xray instance + its dedicated PostgreSQL + RabbitMQ. Joins
Artifactory 1 via a shared `joinKey` so it can scan AF's repositories.

## Status: scaffold

The compose comes up and the services start. The actual "Xray usable for
ticket reproduction" state depends on:

1. Your `ARTIFACTORY_LICENSE` including Xray entitlements (EnterpriseX or
   trial-with-Xray). If your license doesn't, Xray will start but the AF
   integration won't enable.
2. First-time Xray initialization (DB migrations, indexer warmup) can take
   3–5 minutes after the container reports "started".

## What runs

| Container | Image | Purpose |
|---|---|---|
| `arti-xray` | `releases-docker.jfrog.io/jfrog/xray` | Main Xray service (all microservices bundled) |
| `postgres-xray` | `postgres:15` | Xray's own DB (db: `xraydb`) |
| `rabbitmq-xray` | `rabbitmq:3-management` | Message bus |

| Port | Maps to | Notes |
|---|---|---|
| `${XRAY_PORT}` (default 8000) | container 8000 | Xray UI / API |

## Wiring to Artifactory

The `joinKey` in `config/xray/system.yaml` must equal the `joinKey` in
`config/art1/system.yaml`. Both default to a baked-in **dev-only** value —
fine for localhost, please regenerate before any other use:

```bash
openssl rand -hex 16   # 32 hex chars
```

Update both files and `./arti-deployer reset && up`.

## Verifying

```bash
# Tail Xray logs during startup
./arti-deployer logs xray

# Once "Server is ready" appears:
open http://localhost:8000

# In AF1 UI: Administration → Xray → Settings — should show the connected
# Xray node.
```

## Known limitations of this scaffold

- **No separate Xray license file.** Relies on the shared license model
  where AF's license covers Xray. If you have a standalone `xray.lic`,
  drop it at `config/xray/xray.lic` and add a bind-mount in
  `compose/xray.yml`.
- **Single-node only.** No HA topology.
- **No scan policy bootstrap.** You'll need to configure watches /
  policies / indexed repos manually in the UI.

These are reasonable v2 additions if the team finds Xray tickets benefit.

## Troubleshooting

**Xray container restart loops** — usually `joinKey` mismatch. Compare:
```bash
docker exec artifactory1 cat /var/opt/jfrog/artifactory/etc/security/master.key
docker exec arti-xray   cat /var/opt/jfrog/xray/etc/security/master.key
```
…they should match.

**"Failed to connect to Artifactory"** — check `xray` container's resolved
`jfrogUrl`. It should be `http://artifactory1:8082` (the internal docker
hostname), not `localhost`.

**RabbitMQ connection refused** — `rabbitmq-xray` may still be starting.
Xray retries; give it a minute.

**Out of memory** — Xray indexer + analysis are heavy. Bump Docker
Desktop's memory allocation to 12+ GB.
