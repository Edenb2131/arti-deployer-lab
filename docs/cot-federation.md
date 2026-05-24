# Two instances + Circle of Trust + Access Federation

When the wizard picks **2 instances**, the CLI runs `configure-cot.sh` after
both Artifactories are healthy. That script does six things:

1. **Bearer tokens** — exchanges admin basic creds for short-lived Access
   tokens (`POST /access/api/v1/tokens`). Required for the rest of the flow:
   `/access/api/v1/*` rejects basic auth in AF 7.100+.
2. **Custom Base URLs** — sets each AF's base URL to its docker-internal
   hostname (`http://artifactory1:8082/artifactory`,
   `http://artifactory2:8082/artifactory`). Federated repos refuse to be
   created without this.
3. **Root certs** — fetches each AF's Access root cert.
4. **Cross-trust** — `POST /access/api/v1/system/trusted_keys` on each AF
   with the other's cert. This is the cryptographic CoT handshake.
5. **JPD pairing** — generates a pairing token on art1
   (`POST /access/api/v1/system/jpd/pair`) and consumes it on art2
   (`POST /access/api/v1/system/jpd/bind`). Falls back to the older
   topology `federation_target` endpoint if the modern one isn't available.
6. **Smoke test repos** — creates `generic-fed` and `docker-fed` federated
   repos on art1 with both AFs as members, using the correct docker-internal
   URLs.

## ⚠️ The federation member URL gotcha

When you add a federation member in the UI, you'll see something like:

```
URL: http://localhost:8182/artifactory/my-fed-repo
        ↑                  ↑
    WRONG — AF can't       The host port (8182 = AF2 from your laptop's
    reach 'localhost'      browser). But AF1 talks to AF2 over the docker
    on host port from      bridge, not via your host's published ports.
    inside its container
```

…and it'll fail with:

```
✗ Connect to localhost:8182 [localhost/127.0.0.1, localhost/0:0:0:0:0:0:0:1]
  failed: Connection refused
```

**The fix:** always use the docker-internal hostname for federation member
URLs:

```
✓ http://artifactory2:8082/artifactory/my-fed-repo
  ↑                       ↑
  AF2's container hostname on the docker bridge net
                          container port 8082 (router) — fixed,
                          not the host-side port
```

Same in reverse: art2 → art1 federation members use
`http://artifactory1:8082/artifactory/...`

This is *only* true for the federation member URL field. Your browser
keeps using `http://localhost:8082/ui/` etc — that's host-side, fine.

## What configure-cot.sh creates for you

| Repo key | Package type | Members |
|---|---|---|
| `generic-fed` | Generic | `http://artifactory1:8082/artifactory/generic-fed`, `http://artifactory2:8082/artifactory/generic-fed` |
| `docker-fed`  | Docker  | `http://artifactory1:8082/artifactory/docker-fed`, `http://artifactory2:8082/artifactory/docker-fed` |

Upload a file to art1's `generic-fed` — it should mirror to art2 within
seconds (visible at `http://localhost:8181/ui/repos/tree/General/generic-fed`).

## Verify in UI

| Check | Where |
|---|---|
| Trust established | art1 → Administration → User Management → **Trusted Keys** |
| JPD bound | art1 → Administration → User Management → **Access Federation** |
| Federated repos | art1 → Administration → Repositories → `generic-fed` / `docker-fed` → Members |

## Internal vs external URLs (the rule)

| What | Uses | Why |
|---|---|---|
| Your browser URL | host: `localhost:8082` | Your laptop reaches AF via the published host ports |
| Federation member URL | docker: `artifactory2:8082` | AF reaches AF over the docker bridge net |
| Custom Base URL | docker: `artifactory{1,2}:8082/artifactory` | Other AFs need to reach this one — docker bridge again |
| AF1's `jfrogUrl` (if set) | docker: `artifactory1:8082` | Internal use only |

If you ever need cross-instance traffic to flow through your host (rare),
publish AF2 on the same network namespace as AF1 — but that's beyond what
this lab targets.

## Manual re-run

```bash
rm .arti-deployer/.cot-configured
./arti-deployer down
./arti-deployer up      # or: bash scripts/configure-cot.sh
```

## When the auto-bootstrap returns warnings

`configure-cot.sh` does best-effort across AF versions — the Access API
shape has shifted. If something logs a `⚠`, the script will tell you which
step. Most failures resolve to one of:

- **Pair endpoint 404 / 405** — AF version doesn't expose
  `/access/api/v1/system/jpd/pair`. The script auto-falls-back to the
  older topology endpoint. If that also fails, configure manually:
  Admin → User Management → Access Federation → **Add JPD**, paste a
  pairing token generated on the other instance.
- **trusted_keys 409** — already trusted from a prior run. Harmless.
- **Repo create 400** — likely a base URL issue. Re-run after a minute
  (CoT propagation can take 30-60s on first bind), or check that step 2
  set the base URL correctly.

## What this can't (yet) test

- Replication (push/pull) between independent AFs — different from federation
- Edge-node topology
- HA (multi-node sharing one DB + filestore)

These are good "v2" additions. See [docs/extending.md](extending.md).
