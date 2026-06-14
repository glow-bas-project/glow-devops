# Edge proxy (`glow-traefik`)

HTTP-only reverse proxy for the local Compose stack. TLS is not configured.

## Environment variables

Set in [`compose/.env`](../.env.example) (see `compose/.env.example`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `TRAEFIK_HTTP_PORT` | `80` | Host port mapped to Traefik `web` entrypoint |
| `GLOW_EDGE_HOST` | `localhost` | Host for Java API path routes and Keycloak |
| `GLOW_AUTH_PATH` | `/auth` | Path prefix for Keycloak (no strip-prefix) |
| `authBaseUrl` | `http://localhost/auth` | Public Keycloak frontend URL (`KC_HOSTNAME`) |

If `TRAEFIK_HTTP_PORT` is not `80`, use that port in all URLs below (e.g. `http://localhost:8880/auth/admin`).

## Routing

| Compose service | Public URL (default port 80) | Traefik rule |
|-----------------|------------------------------|--------------|
| `glow-ui` | `http://localhost/` | `Host(localhost)` catch-all |
| `keycloak` | `http://localhost/auth/admin`, `http://localhost/auth/realms/...` | `Host(localhost)` + `PathPrefix(/auth)` |
| `glow-restaurant` | `http://localhost/api/restaurant/...` | `Host(localhost)` + `PathPrefix(/api/restaurant)` + strip prefix |
| `glow-user` | `http://localhost/api/user/...` | `/api/user` |
| `glow-order` | `http://localhost/api/order/...` | `/api/order` |
| `glow-cart` | `http://localhost/api/cart/...` | `/api/cart` |
| `glow-courier` | `http://localhost/api/courier/...` | `/api/courier` |
| `glow-menu` | `http://localhost/api/menu/...` | `/api/menu` |
| `glow-payment` | `http://localhost/api/payment/...` | `/api/payment` |

Service path names drop the `glow-` prefix from the compose service key (`glow-restaurant` → `/api/restaurant`).

Traefik picks the longest matching rule, so `/auth` and `/api/*` win over the UI catch-all without explicit router priorities. The SPA must be built with public origin `http://localhost`, Keycloak URL `http://localhost/auth`, and API base `http://localhost/api`.

Postgres (`5432`) is not routed through Traefik.

## Adding a new `glow-*` service

1. Add the service block in [`docker-compose.yml`](../docker-compose.yml) with `<<: *glow_java_env` and JDBC/OIDC env.
2. Add Traefik labels (copy from an existing service):
   - `<<: *glow_traefik_common`
   - Router: `Host(\`${GLOW_EDGE_HOST}\`) && PathPrefix(\`/api/<path>\`)` where `<path>` is the service key without `glow-` (e.g. `glow-foo` → `/api/foo`)
   - Middleware: `stripprefix` with the same prefix (`/api/foo`)
   - Service port label: `8080`
3. Do not publish host `ports:` unless debugging without Traefik.
4. Document the public URL in this table.

## Kubernetes

The same URL layout applies on Kubernetes, but edge routing differs by environment:

| Environment | Edge | Docs |
|-------------|------|------|
| Local k3d | k3d built-in Traefik + `Ingress` → `glow-api-proxy` | [helm/README.md](../../helm/README.md#http-routing) |
| Orbit production | Platform Envoy Gateway + `HTTPRoute` → `glow-api-proxy` | [helm/README.md](../../helm/README.md#http-routing) |

Compose is the only stack that runs the dedicated `glow-traefik` container. k3d uses its bundled Traefik; Orbit uses the university cluster gateway.
