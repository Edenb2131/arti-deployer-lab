# LDAP overlay

Spins up an OpenLDAP server and wires it into Artifactory 1 as an LDAP
authentication source + group mapping.

## Status: scaffold

This is wired end-to-end with sample users, but the **sample LDIF is a
placeholder**. For the real JFrog support fixture set, replace
`config/ldap/ldifs/01-users-and-groups.ldif` with content from
[github.jfrog.info/JFROG/ldapsetupforartifactory](https://github.jfrog.info/JFROG/ldapsetupforartifactory)
(`ldapServer-61a5`).

## What runs

- **Container:** `arti-openldap` (image: `bitnami/openldap`)
- **Base DN:** `dc=jfrog,dc=local`
- **Admin DN:** `cn=admin,dc=jfrog,dc=local`
- **Admin password:** `${LDAP_ADMIN_PASSWORD}` from `.env`
- **Ports:** `${LDAP_PORT}` → 1389 (LDAP), `${LDAP_TLS_PORT}` → 1636 (LDAPS)

## Sample users (in the placeholder LDIF)

| UID | Password | Groups |
|---|---|---|
| `alice` | `Password123` | `developers` |
| `bob`   | `Password123` | `developers` |
| `carol` | `Password123` | `admins` |

## How AF gets wired

`scripts/configure-ldap.sh` runs after AF is healthy. It PATCHes the
system configuration endpoint with:

- `security.ldapSettings.ldap-local` — server URL + bind credentials
- `security.ldapGroupSettings.ldap-groups-local` — group mapping (static)

Verify in UI:
- Administration → Security → **LDAP** — should show `ldap-local` enabled
- Administration → Security → **LDAP Groups** — should show one mapping
- Test login at `/ui/` with `alice` / `Password123` — user is auto-created
  on first login because `autoCreateUser: true`.

## Swapping in the real LDIF

```bash
# Pull the internal fixture (requires VPN / JFrog SSO):
git clone https://github.jfrog.info/JFROG/ldapsetupforartifactory \
  /tmp/ldap-fixture

# Copy LDIFs in (file naming order matters — Bitnami applies alphabetically):
cp /tmp/ldap-fixture/*.ldif config/ldap/ldifs/

# Reset just the LDAP bits:
./arti-deployer down
rm .arti-deployer/.ldap-configured
./arti-deployer up
```

If the real LDIF uses a different base DN, update `LDAP_ROOT` in
`compose/ldap.yml` and the matching `ldapUrl` / search bases in
`scripts/configure-ldap.sh`.

## Troubleshooting

**`ldapsearch` says "Invalid credentials"** — `LDAP_ADMIN_PASSWORD` in
`.env` must match what was set when the openldap volume was first
initialized. Bitnami doesn't re-bootstrap on volume restart.
`./arti-deployer reset` wipes the volume so the new password takes.

**AF says "LDAP server unreachable"** — make sure AF is on the same network.
`docker inspect artifactory1 | jq '.[0].NetworkSettings.Networks'` should
show `arti-deployer_net`.

**Patch returns 400** — the `system.security.ldapSettings` schema differs
slightly across AF versions. Check `./arti-deployer logs artifactory1` for
the specific complaint and adjust `scripts/configure-ldap.sh`.

**Users log in but get no permissions** — by default LDAP users are
auto-created but assigned to no groups. Either:
- Add a default group via Admin UI → Security → Default Groups
- Add a permission target that grants `ldap-groups-local` access
