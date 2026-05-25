# Edge proxy (`glow-traefik`)

HTTP-only reverse proxy for the local Compose stack. TLS is not configured.

## Hosts file

Add this line so Keycloak resolves on your machine (macOS/Linux: `/etc/hosts`, Windows: `C:\Windows\System32\drivers\etc\hosts`):

```text
127.0.0.1 auth.localhost
```

Some systems resolve `*.localhost` automatically; keep the entry for predictable behavior.

## Environment variables

Set in [`compose/.env`](../.env.example) (see `compose/.env.example`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `TRAEFIK_HTTP_PORT` | `80` | Host port mapped to Traefik `web` entrypoint |
| `GLOW_EDGE_HOST` | `localhost` | Host for Java API path routes |
| `GLOW_EDGE_AUTH_HOST` | `auth.localhost` | Host for Keycloak |

If `TRAEFIK_HTTP_PORT` is not `80`, use that port in all URLs below (e.g. `http://auth.localhost:8880/admin`).

## Routing

| Compose service | Public URL (default port 80) | Traefik rule |
|-----------------|------------------------------|--------------|
| `keycloak` | `http://auth.localhost/admin`, `http://auth.localhost/realms/...` | `Host(auth.localhost)` |
| `glow-restaurant` | `http://localhost/restaurant/...` | `Host(localhost)` + `PathPrefix(/restaurant)` + strip prefix |
| `glow-user` | `http://localhost/user/...` | `/user` |
| `glow-order` | `http://localhost/order/...` | `/order` |
| `glow-cart` | `http://localhost/cart/...` | `/cart` |
| `glow-courier` | `http://localhost/courier/...` | `/courier` |
| `glow-menu` | `http://localhost/menu/...` | `/menu` |
| `glow-payment` | `http://localhost/payment/...` | `/payment` |

Path names drop the `glow-` prefix from the compose service key (`glow-restaurant` → `/restaurant`).

Postgres (`5432`) is not routed through Traefik.

## Adding a new `glow-*` service

1. Add the service block in [`docker-compose.yml`](../docker-compose.yml) with `<<: *glow_java_env` and JDBC/OIDC env.
2. Add Traefik labels (copy from an existing service):
   - `<<: *glow_traefik_common`
   - Router: `Host(\`${GLOW_EDGE_HOST}\`) && PathPrefix(\`/<path>\`)` where `<path>` is the service key without `glow-` (e.g. `glow-foo` → `/foo`)
   - Middleware: `stripprefix` with the same prefix
   - Service port label: `8080`
3. Do not publish host `ports:` unless debugging without Traefik.
4. Document the public URL in this table.

## Kubernetes (later)

- `GLOW_EDGE_AUTH_HOST` → Ingress host for Keycloak
- `GLOW_EDGE_HOST` + path prefixes → API Ingress / `IngressRoute` + strip-prefix middleware

Manifests are not in this repository yet.
