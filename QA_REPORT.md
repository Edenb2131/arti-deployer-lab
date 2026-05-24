# QA Report — Full Matrix Run (2026-05-24)

## TL;DR

**24 of 24 active combinations PASSED.** Every combination of
`{1, 2 instances} × {no-nginx, http, https} × {0,1 LDAP} × {0,1 Keycloak}`
runs to healthy AF + reverse-proxied ping in under 4 minutes.

Total runtime: **59 minutes** for 24 combos (~2.5 min average — Docker
image layers stay warm across runs).

7 bugs were found and fixed during this run; commits are pushed to main.

---

## Result matrix

| Code | Instances | NGINX | LDAP | Keycloak | Status |
|---|---|---|---|---|---|
| t01 | 1 | none  | 0 | 0 | ✅ PASS |
| t03 | 1 | none  | 0 | 1 | ✅ PASS |
| t05 | 1 | none  | 1 | 0 | ✅ PASS |
| t07 | 1 | none  | 1 | 1 | ✅ PASS |
| t09 | 1 | http  | 0 | 0 | ✅ PASS |
| t11 | 1 | http  | 0 | 1 | ✅ PASS |
| t13 | 1 | http  | 1 | 0 | ✅ PASS |
| t15 | 1 | http  | 1 | 1 | ✅ PASS |
| t17 | 1 | https | 0 | 0 | ✅ PASS |
| t19 | 1 | https | 0 | 1 | ✅ PASS |
| t21 | 1 | https | 1 | 0 | ✅ PASS |
| t23 | 1 | https | 1 | 1 | ✅ PASS |
| t25 | 2 | none  | 0 | 0 | ✅ PASS |
| t27 | 2 | none  | 0 | 1 | ✅ PASS |
| t29 | 2 | none  | 1 | 0 | ✅ PASS |
| t31 | 2 | none  | 1 | 1 | ✅ PASS |
| t33 | 2 | http  | 0 | 0 | ✅ PASS |
| t35 | 2 | http  | 0 | 1 | ✅ PASS |
| t37 | 2 | http  | 1 | 0 | ✅ PASS |
| t39 | 2 | http  | 1 | 1 | ✅ PASS |
| t41 | 2 | https | 0 | 0 | ✅ PASS |
| t43 | 2 | https | 0 | 1 | ✅ PASS |
| t45 | 2 | https | 1 | 0 | ✅ PASS |
| t47 | 2 | https | 1 | 1 | ✅ PASS |

**Totals: 24 PASS, 0 FAIL.**

## Bugs found and fixed during this run

7 distinct bugs, all pushed to main:

| # | Commit | Bug |
|---|---|---|
| 1 | `ed70c08` | CLI: no way to run non-interactively (TUI-only) |
| 2 | `1adcc2b` | CLI: flag-detection logic inverted — `--instances` triggered the wizard |
| 3 | `5660101` | Compose: license bind-mount on `/var/opt/jfrog/.../etc/artifactory/` raced AF volume init → container stuck in Created |
| 4 | `4e47370` | Bootstrap: `shared.security` in system.yaml blocked router init (later superseded) |
| 5 | `d424924` | **The big one.** Custom-mounted system.yaml prevented the JFrog router (`jfrou`) from ever starting → all other microservices looped forever on "registration with router failed". Switched to env-var-based config (matches JFrog's published compose example) |
| 6 | `0482d4c` | lib.sh: wait_for_af polled `/router/api/v1/system/health` on the legacy HTTP port (8081, where that path 404s) and used a 5-min timeout (cold AF takes ~6) |
| 7 | `709ecf8` | Compose overlays: `arti-deployer_net` declared as `external: true` in overlays but `driver: bridge` in art1.yml. Compose-merge picked the external declaration → every overlay combo failed in 1 sec with "network not found". 23/24 combos failed for this single reason in matrix round 1. |

## Timing observations

| Combo type | Average | Range |
|---|---|---|
| Single instance, no overlays | 1 min | — |
| Single instance + 1 overlay  | 2 min | 1-3 min |
| Single instance + 2 overlays | 3 min | 2-4 min |
| Single instance + nginx-https + ldap + keycloak | 3-4 min | — |
| Dual instance, no overlays   | 3 min | — |
| Dual instance + all overlays | 4 min | 3-4 min |

Faster than initially predicted (8-12 min) — Docker image layers were
warm across runs, and named-volume artifactory data was reused. First-boot
AF when its Postgres + data volume are fresh takes ~5 min; subsequent
boots in the same matrix session reuse cached state.

## What the matrix verifies

For each PASS, the harness verified:

- ✅ `docker compose up -d` returned 0
- ✅ AF1's `/artifactory/api/system/ping` returns 200 within 10 min
- ✅ For 2-instance combos, AF2's ping also returns 200
- ✅ For NGINX combos, the reverse-proxied ping at port 8080 (or 8443)
  returns 200

What it does **NOT** verify (acknowledged gaps):

- ❌ **CoT bootstrap actually succeeded** for 2-instance combos. The
  `configure-cot.sh` runs but its REST calls' return codes aren't
  asserted by the harness. The script logs warnings on failure and
  continues. To validate, check `/access/api/v1/system/trusted_keys`
  on each AF after a 2-instance combo lands.
- ❌ **LDAP integration actually wired into AF** — the harness runs
  `configure-ldap.sh` but doesn't try logging in as `user1` afterward
  to confirm the LDAP-backed auth works.
- ❌ **Keycloak OIDC token exchange end-to-end** — script registers the
  provider in Access but doesn't perform a real token exchange.
- ❌ **Federated repo replication** — the smoke uploads no files, so
  the `generic-federated` repo created by configure-cot is never tested
  for actual mirroring between art1 and art2.

These are good targets for a future "deep smoke" pass. The current
harness is a "everything starts and stays healthy" verification, not
"every feature works correctly."

## Reproducing this run

```bash
cd /Users/edenb/Documents/arti-deployer-lab
./arti-deployer init        # bootstrap .env with fresh secrets
# (paste your license into ARTIFACTORY_LICENSE in .env, or use the
# wizard's per-instance license prompt)
bash /tmp/arti-qa/run-matrix.sh --reset
```

Per-combo results are in `/tmp/arti-qa/results/<id>.json`, container
logs in `/tmp/arti-qa/logs/<id>/`, and the running summary in
`/tmp/arti-qa/state/runs.txt`.

## Suggested next steps

1. **Deep-smoke pass** — extend harness to validate CoT trust, LDAP
   user login, OIDC token exchange, federated repo upload+sync.
2. **HA / replication overlays** — currently only dual-instance with
   CoT/federation is covered. Push/pull replication between independent
   AFs and a true HA topology (multi-node sharing one DB + filestore)
   are good additions.

## Notes on env / setup gotchas hit overnight

- **Docker Desktop daemon got wedged** mid-way after a stuck `docker rm`
  on an unsuccessfully-starting container. Required manual force-quit
  + relaunch. Not a code bug, but worth knowing — if this lab is
  hammered with many up/down cycles, expect occasional daemon hangs.
  The matrix runner's `hard_cleanup` uses
  `docker compose down -v --remove-orphans` which is robust against
  this in normal operation.
- **macOS bash 3.2** (the system bash) lacks `globstar` and `timeout`;
  the lab's scripts use `find -print0` and a portable `run_with_timeout`
  helper to compensate. No `brew install coreutils` needed.
