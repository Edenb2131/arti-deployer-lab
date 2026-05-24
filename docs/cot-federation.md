# Two instances + Circle of Trust + Federation

When the wizard picks **2 instances**, `arti-deployer up` runs
`scripts/configure-cot.sh` after both AFs are healthy. That gives you a
working federation between art1 and art2 using only `admin/password`
auth — no manual UI clicks.

## What the script does (in order)

1. **Filesystem Circle of Trust.** Cross-copies each AF's
   `/var/opt/jfrog/artifactory/etc/access/keys/root.crt` into the other
   AF's `etc/access/keys/trusted/` directory via `docker cp`. Access
   auto-ingests the cert within ~15-30s (the file vanishes from
   `trusted/` once imported). This is the entire CoT mechanism — it's a
   filesystem operation, not an API call. Confirmed by the JFrog docs
   step "Creating Circle of Trust".

2. **Bootstrap Access admin tokens.** Each AF generates its own
   `jfmc@<id>.token` on first boot at
   `/var/opt/jfrog/artifactory/work/mc/temp/access-client-config-store/*/keys/jfmc@*.token`.
   The script reads that file via `docker exec` and uses it to mint a
   `*@*` admin Access token via `POST /access/api/v1/tokens`. That
   bearer is then good for any Access or MC REST call. (AF 7.100+
   rejects Basic auth on `/access/api/v1/*` and the legacy Artifactory
   token endpoint refuses to mint Access-audience tokens from admin
   credentials, so this is the only path.)

3. **Custom Base URLs.** PUTs each AF's docker-internal hostname to
   `/artifactory/api/system/configuration/baseUrl`. Federation refuses
   to operate without one.

4. **Smoke test.** Creates a temporary federated repo
   `arti-deployer-cot-smoke`, uploads a file to art1, polls art2 until
   the file appears, then deletes the repo and file on both sides. So
   the script verifies federation actually replicates without leaving
   demo state behind.

After this runs, you can push to `art1` and pull from `art2` (or vice
versa) using any federated repo whose members point at the docker
hostnames.

## ⚠️ The federation member URL gotcha

When you create a federated repo in the UI, the URL you enter for a
member matters:

```
URL: http://localhost:8182/artifactory/my-fed-repo
        ↑                  ↑
    WRONG — AF can't       The host port (8182 = art2 from your
    reach 'localhost'      laptop's browser). But art1 talks to art2
    on host port from      over the docker bridge, not via your host's
    inside its container   published ports.
```

…and you'll see:

```
✗ Connect to localhost:8182 [localhost/127.0.0.1, localhost/0:0:0:0:0:0:0:1]
  failed: Connection refused
```

**The fix:** use the docker-internal hostname:

```
✓ http://artifactory2:8082/artifactory/my-fed-repo
  ↑                       ↑
  art2's docker hostname   container port 8082 (router) — fixed,
  on the bridge net        NOT the host-side port (8181/8182)
```

Same in reverse from art2 → art1 uses `http://artifactory1:8082/...`.

This is **only** the federation-member URL. Your browser keeps using
`http://localhost:8082/ui/` etc — that's host-side and works fine.

## Easy mode: `./arti-deployer fed-repos`

To skip manually entering URLs every time, pre-create one federated
repo per common package type:

```bash
./arti-deployer fed-repos
```

Creates these on art1 (auto-propagates to art2 via federation):

| Repo key | Package type |
|---|---|
| `generic-fed` | generic |
| `docker-fed`  | docker  |
| `maven-fed`   | maven   |
| `npm-fed`     | npm     |
| `pypi-fed`    | pypi    |
| `helm-fed`    | helm    |
| `nuget-fed`   | nuget   |
| `gradle-fed`  | gradle  |
| `composer-fed`| composer|
| `go-fed`      | go      |

Each has members `http://artifactory{1,2}:8082/artifactory/<key>`
already wired. Push to art1 → it replicates to art2 in ~30s.

```bash
./arti-deployer fed-repos list      # show which are present
./arti-deployer fed-repos --delete  # remove them all
```

To add another package type, append it to the `REPO_TYPES=(…)` array in
`scripts/fed-repos.sh`.

### Docker push example

```bash
docker pull hello-world
docker tag hello-world localhost:8082/docker-fed/hello-world:latest
docker login localhost:8082 -u admin -p password
docker push localhost:8082/docker-fed/hello-world:latest

# Wait ~30s, then verify on art2
docker pull localhost:8182/docker-fed/hello-world:latest
```

If `docker login`/`push` complains about HTTP / insecure registry, add
`localhost:8082` and `localhost:8182` to Docker Desktop's
**Insecure Registries** list (Settings → Docker Engine → JSON), or
push via NGINX HTTPS (`https://localhost:8443/docker-fed/…`) after
trusting the self-signed cert.

## What's NOT implemented — JPD UI visibility

The Administration → Topology → JPD Services page will only show the
local JPD (HOME). Adding the peer as a registered JPD requires either:

- The standalone **JFrog Mission Control** product (separate
  `jfrog/mission-control:*` deployment) — its API can complete the
  JPD-pairing token handshake.
- Or manual UI workflow with a pairing token — not currently exposed
  by AF Pro's embedded `mc` microservice.

I tried direct DB inserts into `mc_jpd` + `mc_service` +
`mc_service_node` — the JPDs appear in the API but the UI renders
**blank** because the JS bundle expects coherent data across
`mc_jpd_edge_status` + `mc_jpd_license` (whose `custom_data` is a
serialized binary blob). The hack is in git history at commit
`63bc9dd` (reverted in `c057868`) if a future contributor wants to
take another crack at it.

**Bottom line:** federation works (push to one, read from the other).
The Topology UI just doesn't show the peer JPD as a card. The
federated-repo "Add Members → Deployments" dropdown also says "Remote
JPDs not found" — use the **URL** tab instead with the docker hostname.

## Manual re-run

```bash
rm .arti-deployer/.cot-configured
./arti-deployer down
./arti-deployer up      # configure-cot.sh runs again
```

## What this lab can't (yet) test

- Replication (push/pull) between independent AFs — different from
  federation
- Edge-node topology
- HA (multi-node sharing one DB + filestore)

These are good v2 additions. See [docs/extending.md](extending.md).
