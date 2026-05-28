# Compose local configuration

Runtime settings for Java services are injected via **environment variables** in [`docker-compose.yml`](docker-compose.yml), with secrets and shared values in **`compose/.env`** (not in service repositories).

Edge routing (Traefik hostnames, paths, ports) is configured separately — see [Edge proxy (`glow-traefik`)](#edge-proxy-glow-traefik) and [`traefik/README.md`](traefik/README.md).

## Setup

```bash
cp compose/.env.example compose/.env
```

Add to your hosts file (see [`traefik/README.md`](traefik/README.md)):

```text
127.0.0.1 auth.localhost
```

Edit `compose/.env` and set at least:

| Variable | Purpose |
|----------|---------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Postgres, Keycloak DB, Quarkus datasource |
| `REGISTRY_PREFIX` / `IMAGE_TAG` | Default image when not using `glowBuild` local tag |
| `TRAEFIK_HTTP_PORT` / `GLOW_EDGE_HOST` / `GLOW_EDGE_AUTH_HOST` | Edge proxy (defaults usually fine) |
| `GLOW_USER_OIDC_CLIENT_SECRET` | Keycloak client secret for `glow-user-service` |

Get the OIDC secret from Keycloak admin: `http://auth.localhost/admin` → realm `glow-realm` → Clients → `glow-user-service` → Credentials.

If `GLOW_USER_OIDC_CLIENT_SECRET` is empty, the container still starts but OIDC fails.

## Edge proxy (`glow-traefik`)

`glow-traefik` is the single HTTP entry on `${TRAEFIK_HTTP_PORT:-80}` (no TLS in local compose).

| Traffic | URL (port 80) |
|---------|----------------|
| Keycloak admin / OIDC from host | `http://auth.localhost/...` |
| Java APIs from host | `http://localhost/<path>/...` (e.g. `/restaurant`, `/user`) |

Postgres stays on `localhost:5432`. App containers are not published on `8080`–`8087` anymore.

Full routing table and “add a service” steps: [`traefik/README.md`](traefik/README.md).

### Keycloak hostnames (`KC_HOSTNAME` vs admin)

`QUARKUS_OIDC_AUTH_SERVER_URL` is `http://keycloak:8080/...`, but Quarkus also reads **OpenID discovery** and uses the `token_endpoint` / `jwks_uri` from that JSON. If Keycloak is configured with `KC_HOSTNAME=localhost`, discovery advertises `http://localhost/...`. Inside `glow-user`, `localhost` is the app container, not Keycloak → `Connection refused`.

Compose sets:

- `KC_HOSTNAME: http://keycloak:8080` — URLs for services on the Docker network
- `KC_HOSTNAME_ADMIN: http://auth.localhost` — admin console and host-side token/curl via Traefik

After changing Keycloak env, recreate Keycloak and the app:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml up -d --force-recreate keycloak
cd ../glow-user-service && ./gradlew glowBuild
```

## Container memory sizes

Anchors in `docker-compose.yml` (limit per container):

| Size | Memory limit |
|------|----------------|
| `x-glow-size-small` | 600M |
| `x-glow-size-medium` | 1G |
| `x-glow-size-large` | 1200M |

All services currently use `<<: *glow_size_medium`. Change a service to `*glow_size_small` or `*glow_size_large` when needed.

## Per-service env (in `docker-compose.yml`)

Shared anchor `x-glow-java-env`: HTTP, OIDC server URL, TLS, Postgres user/password.

Each service adds its own JDBC URL and OIDC client settings, for example `glow-user`:

- `QUARKUS_DATASOURCE_JDBC_URL`
- `QUARKUS_OIDC_CLIENT_ID`
- `QUARKUS_OIDC_CREDENTIALS_SECRET` (from `.env`)

Traefik labels use anchor `x-glow-traefik-common` plus per-service path prefix (see `traefik/README.md`).

When adding a service, extend `docker-compose.yml` and `.env.example`; do not put connection strings or secrets in the service repo.

## Kubernetes

Use the same Quarkus env names on Deployments (ConfigMap / Secret). Map `GLOW_EDGE_AUTH_HOST` and API paths to Ingress rules later. Service JARs only ship non-environment defaults (Liquibase, Hibernate, etc.).
