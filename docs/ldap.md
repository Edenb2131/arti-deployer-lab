# LDAP overlay

Spins up `osixia/openldap` and wires it into Artifactory 1, matching the
structure produced by JFrog support's `ldapsetupforartifactory` newscript.sh.

## What runs

- **Container:** `arti-openldap` (image: `osixia/openldap`)
- **Base DN:** `dc=example,dc=org`
- **Admin DN:** `cn=admin,dc=example,dc=org`
- **Admin password:** `${LDAP_ADMIN_PASSWORD}` from `.env`
- **Ports:** `${LDAP_PORT}` → 389 (LDAP), `${LDAP_TLS_PORT}` → 636 (LDAPS)

## Directory structure (after bootstrap)

```
dc=example,dc=org
└── ou=Organization
    ├── ou=Users
    │   ├── cn=User1   (uid=user1)
    │   ├── cn=User2   (uid=user2)
    │   ├── cn=User3   (uid=user3)
    │   └── cn=User4   (uid=user4)
    └── ou=Groups
        ├── cn=group1  (members: user1, user2, user3)
        └── cn=group2  (members: user1, user2, user3)
```

All user passwords come from `${LDAP_USER_PASSWORD}` in `.env` (auto-generated
by `./arti-deployer init`).

## How AF gets wired

`scripts/configure-ldap.sh` runs after AF is healthy and POSTs two payloads,
matching newscript.sh's curl commands verbatim:

- `POST /artifactory/ui/ldap` — server settings
  - `searchFilter: (uid={0})`
  - `managerDn: cn=admin,dc=example,dc=org`
  - `autoCreateUser: true`, `ldapPoisoningProtection: true`
- `POST /artifactory/ui/ldapgroups/ldapgroup` — STATIC group mapping
  - `groupNameAttribute: cn`, `groupMemberAttribute: member`
  - `filter: (objectClass=groupOfNames)`

Verify in UI:
- Administration → Security → **LDAP** — `openldap` entry, enabled
- Administration → Security → **LDAP Groups** — `openldap-groups` mapping
- Test login at `/ui/` with `user1` / your `${LDAP_USER_PASSWORD}`

## Adding more users / groups

Drop more `.ldif.tmpl` files in `config/ldap/ldifs/` (numeric prefix orders
them). `${LDAP_USER_PASSWORD}` is the only placeholder you can use. Re-run
`./arti-deployer reset && up` so the LDAP volume re-bootstraps.

## Switching to the AD-emulating image

If you need DYNAMIC group strategy (memberOf attribute on users), swap to
the `dwimberger/ldap-ad-it` image used by your team's second reference script.
That requires:

1. `compose/ldap.yml`: change image, port `10389:10389`, admin DN
   `uid=admin,ou=system`, password `secret`, domain `wimpi.net`
2. New LDIF with `simulatedMicrosoftSecurityPrincipal` objectClass and
   `memberof` attribute on each user
3. `scripts/configure-ldap.sh`: change `searchFilter` to
   `(sAMAccountName={0})`, `groupMemberAttribute: memberof`,
   `strategy: DYNAMIC`

PRs welcome to add an `ldap-ad` overlay alongside the standard one.

## Troubleshooting

**`ldapsearch` returns "Invalid credentials"** — the `${LDAP_ADMIN_PASSWORD}`
in `.env` must match what was set on first volume bootstrap. osixia doesn't
re-set on restart. Wipe with `./arti-deployer reset`.

**AF says "LDAP server unreachable"** — confirm AF is on `arti-deployer_net`:
`docker inspect artifactory1 | jq '.[0].NetworkSettings.Networks'`.

**Users log in but get no permissions** — by default LDAP users are
auto-created but have no group membership in AF. Either configure Default
Groups (Admin → Security) or create a Permission Target that grants
`openldap-groups` access.
