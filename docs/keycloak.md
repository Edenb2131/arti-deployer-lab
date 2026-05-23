# Keycloak overlay

Spins up Keycloak as an OIDC identity provider and wires Artifactory 1 to
trust it as an SSO source.

## Status: scaffold

End-to-end wired with a pre-imported realm, but the AF integration step is
**best-effort** — the Access OIDC API surface has shifted between
AF 7.x point releases. If the auto-config fails, the script logs what to
do manually.

## What runs

- **Container:** `arti-keycloak` (image: `quay.io/keycloak/keycloak:25.0`)
- **Mode:** `start-dev` (embedded H2 DB; not for production)
- **Port:** `${KEYCLOAK_PORT}` → 8080
- **Realm:** `jfrog` (pre-imported from `config/keycloak/realm.json`)
- **Admin:** `admin` / `${KEYCLOAK_ADMIN_PASSWORD}` (from `.env`)

## Realm contents

| Item | Value |
|---|---|
| Client ID | `artifactory` |
| Client Secret | `artifactory-client-secret` |
| Redirect URIs | `localhost:8081/*`, `localhost:8082/*`, `localhost:8080/*`, `https://localhost:8443/*`, `http://artifactory1:8082/*` |
| Test user | `testuser` / `Password123` |
| Admin user | `kcadmin` / `Password123` |
| Roles | `developer`, `admin-role` |

## How AF gets wired

`scripts/configure-keycloak.sh` does two things in order:

1. **Register OIDC provider in Access** —
   `POST /access/api/v1/oidc` with the realm's discovery URL.
2. **Enable OAuth SSO in AF system config** —
   `PATCH /artifactory/api/system/configuration` with
   `security.oauthSettings.oauthProvidersSettings.keycloak`.

If either step returns non-2xx, the script logs the response and points
you at the UI path to finish manually.

## Manual fallback (UI path)

If the auto-config doesn't take:

1. AF UI → **Administration → Identity Providers** → click **OIDC**, add:
   - Name: `keycloak`
   - Issuer URL: `http://localhost:${KEYCLOAK_PORT}/realms/jfrog`
   - Client ID: `artifactory`
   - Audience: `artifactory`
2. AF UI → **Administration → Security → OAuth SSO** → enable, add provider:
   - Type: OpenID
   - Client ID: `artifactory`
   - Client Secret: `artifactory-client-secret`
   - Auth URL: `http://localhost:${KEYCLOAK_PORT}/realms/jfrog/protocol/openid-connect/auth`
   - Token URL: `http://keycloak:8080/realms/jfrog/protocol/openid-connect/token`
   - API URL: `http://keycloak:8080/realms/jfrog/protocol/openid-connect/userinfo`

The **auth URL** must be reachable from your **browser** (so use host:port,
not container hostname). The **token URL** and **API URL** can be either —
AF reaches them from inside its container, so internal names work too.

## Internal vs external URLs (gotcha)

- Browser-facing URLs → `http://localhost:${KEYCLOAK_PORT}/...`
  (used for the `/auth` redirect)
- AF-facing URLs → `http://keycloak:8080/...`
  (used for token validation / userinfo calls)

The pre-imported realm allows both. If you change `KEYCLOAK_PORT`, also
update the redirect URIs in `config/keycloak/realm.json` and re-run with
a wiped Keycloak volume (`./arti-deployer reset`).

## Troubleshooting

**"Invalid redirect_uri"** — your AF URL isn't in the realm's allow-list.
Add it to the client's `redirectUris` in `realm.json` and reset Keycloak.

**Token validation fails after login** — usually a clock skew issue between
host and container. `docker exec arti-keycloak date` vs `date` should agree
within a few seconds.

**`testuser` can log in but has no AF permissions** — Keycloak roles don't
auto-map to AF groups. Set up role-to-group mapping in AF's OAuth SSO
configuration, or use Default Groups.

**Keycloak takes forever to boot in dev mode** — first start imports the
realm; subsequent starts are fast because the H2 data volume persists.
