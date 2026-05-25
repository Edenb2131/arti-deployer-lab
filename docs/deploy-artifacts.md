# deploy-artifacts.py

Add-on that populates the running lab with realistic artifacts across 8
package types — gives you something to click around with after `up`.

## What it does

For each enabled repo type, creates **three** repositories on the target AF:
| rclass | name | source |
|---|---|---|
| local | `<type>-local` | empty, gets the pulled artifacts |
| remote | `<type>-remote` | proxies the type's canonical upstream |
| virtual | `<type>-virtual` | aggregates local + remote |

Then uses `jf` CLI to pull a small set of real packages through the
virtual repo, recording each as a JFrog Build (visible under Builds in
the UI).

Repo types and what gets pulled:
- **docker** — `nginx, httpd, alpine, ubuntu, redis` (via `jf docker pull`)
- **npm** — `express, vue, react, lodash, axios`
- **pypi** — `requests, flask==3.1.1, numpy, pandas, scikit-learn`
- **maven** — `commons-lang3, junit` (via `jf rt dl`)
- **helm** — `nginx, redis` Bitnami charts
- **go** — `gin, gorilla/mux` modules
- **nuget** — `Newtonsoft.Json, log4net`
- **generic** — generates two local text files, uploads, downloads

Optional: `--release-bundles` also creates a Release Bundle per type from
the local repo's contents.

## Prereqs

- Lab is `up` (`./arti-deployer up`)
- `jf` (JFrog CLI) on PATH — `brew install jfrog-cli`
- For each enabled repo type, the corresponding CLI on PATH:
  - `docker`, `npm`, `pip`, `go`
- Python 3.9+ and `pip install -r requirements.txt`

## Common invocations

```bash
# Default: docker + npm + pypi against art1
./deploy-artifacts.py

# Preview only — no API calls, no commands run
./deploy-artifacts.py --dry-run -v

# Wider set
./deploy-artifacts.py --repo-types docker npm pypi maven helm go nuget generic

# Target art2 instead of art1
./deploy-artifacts.py --url http://localhost:8182

# Through the NGINX HTTPS vhost
./deploy-artifacts.py --url https://art1.localtest.me:8443

# Reuse repos from a previous run, just pull more
./deploy-artifacts.py --skip-repo-creation

# Build artifacts only — no pull, no repo create
./deploy-artifacts.py --skip-repo-creation --skip-pull
```

Full flag list: `./deploy-artifacts.py --help`.

## Credential resolution

Highest → lowest priority:
1. CLI flags (`--url`, `--username`)
2. Env vars (`ARTIFACTORY_URL`, `ARTIFACTORY_USERNAME`, `ARTIFACTORY_PASSWORD`)
3. JSON file passed via `--config /path/to.json`
4. Hardcoded `ARTIFACTORY_*` constants at the top of the script
   (currently `http://localhost:8082/`, `admin`, `password`)

The defaults align with the lab's initial state, so `./deploy-artifacts.py`
with no args works against art1 immediately after `./arti-deployer up`.

## Cleanup

The script's own `cleanup()` (run after a successful pass) removes its
working-directory artifacts: `node_modules`, `__pycache__`, `.jfrog`,
`package.json`, `package-lock.json`, `.npmrc`. It also removes the
`jfrog-cli` server config it added.

The **repositories** it created in Artifactory are intentionally left
behind — that's the point. To wipe them, use the lab's standard cleanup:
`./arti-deployer cleanup --force` (also clears the AF data volume).

## Relationship to `./arti-deployer fed-repos`

| | `./arti-deployer fed-repos` | `./deploy-artifacts.py` |
|---|---|---|
| Repo type | federated | local + remote + virtual |
| Repos per package | 1 (`<type>-fed`) | 3 (`<type>-local/-remote/-virtual`) |
| Cross-instance? | yes (members on art1 + art2) | no (single AF) |
| Pulls real packages? | no — empty repos | yes |
| Records Builds? | no | yes |

They're complementary — `fed-repos` gives you the federation/replication
surface; `deploy-artifacts.py` gives you a populated AF with builds.
