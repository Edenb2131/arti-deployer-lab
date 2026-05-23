# Two instances + Circle of Trust + Access Federation

When the wizard picks **2 instances**, the CLI runs `configure-cot.sh` after
both Artifactories are healthy. That script does three things:

1. **Circle of Trust** — fetches each instance's Access root certificate
   (`GET /access/api/v1/system/root_certificate`) and cross-trusts them
   (`POST /access/api/v1/system/trusted_keys`). This is the cryptographic
   handshake that lets the two AFs verify each other's signed payloads.
2. **Access Federation** — registers art2 as a federation target of art1
   (`POST /access/api/v1/topology/federation_target`). Users, groups, and
   permissions created on art1 will propagate to art2.
3. **Smoke test** — creates a `generic-federated` repo on art1 with both
   instances as members. Uploads to it should mirror to art2.

## Best-effort caveat

The Access API surface for CoT has evolved across AF versions. The script is
verified-ish against 7.98.x but you may need to tweak endpoints or payloads
for older / newer versions. If something fails the script logs a warning and
continues — so the lab is still usable and you can fix the rest in the UI.

If you fix something, please PR the endpoint shape back into
`scripts/configure-cot.sh` with a version comment.

## Verify in UI

| Check | Where |
|---|---|
| Trust established | art1 → Administration → User Management → **Trusted Keys** |
| Federation target | art1 → Administration → User Management → **Access Federation** |
| Federated repo | art1 → Administration → Repositories → `generic-federated` → Members |

## Manual re-run

```bash
rm .arti-deployer/.cot-configured
./arti-deployer down
./arti-deployer up      # or: bash scripts/configure-cot.sh
```

## Internal vs external URLs

The script uses **internal** docker network URLs (`http://artifactory1:8082`,
`http://artifactory2:8082`) when configuring federation targets so the AFs
talk to each other over the docker bridge — not over your host's ports.
That's intentional. Don't change them to `localhost:81xx`.

## What you can't (yet) test here

- Replication (push/pull) between independent AFs — different from federation
- Edge-node topology
- HA (multi-node sharing one DB + filestore)

These are good "v2" additions. See [docs/extending.md](extending.md).
