# NGINX overlay

Puts an NGINX reverse proxy in front of Artifactory 1, matching the typical
customer deployment pattern (AF behind nginx).

## Two flavors (mutually exclusive)

| Wizard choice | Compose file | Listens on |
|---|---|---|
| NGINX + HTTPS = no | `compose/nginx.yml` | `${NGINX_HTTP_PORT}` (default 8080) |
| NGINX + HTTPS = yes | `compose/nginx-https.yml` | 80 → redirect to 443; `${NGINX_HTTPS_PORT}` (default 8443) for HTTPS |

The CLI picks one or the other based on `USE_NGINX_HTTPS` — they are not
combined to avoid bind-mount conflicts on `/etc/nginx/nginx.conf`.

## Config files

| File | Purpose |
|---|---|
| `config/nginx/nginx-http.conf` | HTTP-only config, listens on 80 |
| `config/nginx/nginx-https.conf` | HTTPS config with 80→443 redirect |
| `config/nginx/certs/server.{crt,key}` | Self-signed cert (gitignored, generated) |

Both configs include the JFrog-recommended headers:

```
X-JFrog-Override-Base-Url
X-Forwarded-Port / -Proto / -For
Host
```

…and disable the request body size limit (artifacts can be huge).

## Self-signed cert

`scripts/gen-self-signed.sh` runs automatically when HTTPS is enabled. The
cert covers:

- `CN=localhost`
- SAN: `localhost`, `artifactory1`, `artifactory2`, `127.0.0.1`

It's regenerated only if `config/nginx/certs/server.crt` does not exist —
delete it and re-run `./arti-deployer up` to force regeneration.

Browsers will warn on first visit. To suppress for repeat testing, import
`server.crt` into your system keychain and mark it as trusted (macOS:
double-click → Keychain Access → set "Always Trust").

## Where art2 sits in this picture

For v1, NGINX only proxies to art1. If you want NGINX in front of art2 too,
add a second upstream + server block in `nginx-*.conf`:

```nginx
upstream artifactory2 {
  server artifactory2:8082 max_fails=3 fail_timeout=10s;
}

server {
  listen 81;
  # ... same proxy_pass logic but → artifactory2
}
```

…and expose the new port from `compose/nginx*.yml`. PRs welcome.

## Troubleshooting

**502 Bad Gateway** — AF1 is not healthy yet. NGINX retries; check
`./arti-deployer logs artifactory1`.

**Redirect loop on /ui/** — usually the `X-JFrog-Override-Base-Url` doesn't
match what AF's `system.yaml` advertises. Make sure you hit NGINX, not the
backing AF directly, when testing.

**Cert errors in `curl` / `jf` CLI** — pass `--insecure` (curl) or
`--insecure-tls` (jf) when calling the HTTPS endpoint, or trust the cert.
