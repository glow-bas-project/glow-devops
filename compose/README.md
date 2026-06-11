# Compose local configuration

Runtime settings for Java services are injected via **environment variables** in [`docker-compose.yml`](docker-compose.yml), with secrets and shared values in **`compose/.env`** (not in service repositories).

Edge routing (Traefik hostnames, paths, ports) is configured separately — see [Edge proxy (`glow-traefik`)](#edge-proxy-glow-traefik) and [`traefik/README.md`](traefik/README.md).

## Setup

```bash
cp compose/.env.example compose/.env
```

Edit `compose/.env` and set at least:

| Variable | Purpose |
|----------|---------|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Postgres, Keycloak DB, Quarkus datasource |
| `REGISTRY_PREFIX` / `IMAGE_TAG` | Default image when not using `glowBuild` local tag |
| `TRAEFIK_HTTP_PORT` / `GLOW_EDGE_HOST` / `GLOW_AUTH_PATH` | Edge proxy (defaults usually fine) |
| `authBaseUrl` / `authAdminUrl` | Public Keycloak URLs (realm JSON placeholders + `KC_HOSTNAME`) |
| `GLOW_*_OIDC_CLIENT_SECRET` | OIDC client secrets (see [Keycloak](#keycloak)) |

Run `./scripts/ensure-oidc-secrets.sh` to generate OIDC secrets in `compose/.env` before first start.

## Keycloak

**Image:** `quay.io/keycloak/keycloak:26.6`  
**Realm:** `glow-realm` — config in [`keycloak/glow-realm-realm.json`](../keycloak/glow-realm-realm.json)  
**Admin:** http://localhost/auth/admin (`admin` / `admin`, local dev only)

Client secrets live in `compose/.env` (not in git). Confidential clients are listed in [`keycloak/client-secrets.yaml`](../keycloak/client-secrets.yaml) (`clientId` → env var). The realm JSON uses `${GLOW_*_OIDC_CLIENT_SECRET}` placeholders; Keycloak and Quarkus services read the same values.

URL placeholders (`${authBaseUrl}`, `${authAdminUrl}`) are restored on export via [`keycloak/realm-url-placeholders.yaml`](../keycloak/realm-url-placeholders.yaml).

### New developer setup

```bash
cp compose/.env.example compose/.env
./scripts/ensure-oidc-secrets.sh
./scripts/compose-up.sh keycloak
```

On first boot, `--import-realm` imports `glow-realm-realm.json` when the realm does not exist yet. No manual copy of secrets from the admin UI is required.

If Keycloak fails during first import (check `docker logs glow-keycloak`), reset the Keycloak database and recreate the container:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml stop keycloak
docker exec glow-postgres psql -U glow -d postgres -c "DROP DATABASE IF EXISTS keycloak;"
docker exec glow-postgres psql -U glow -d postgres -c "CREATE DATABASE keycloak;"
docker compose --env-file compose/.env -f compose/docker-compose.yml up -d keycloak
```

Java services wait for Keycloak **healthy** (OIDC reachable on `/auth/realms/master`) before starting.

### Export realm (after admin UI changes)

```bash
./scripts/export-keycloak-realm.sh
git diff keycloak/glow-realm-realm.json
```

Optional: `--include-users` writes `keycloak/glow-realm-users-0.json` for dev seeding (not committed by default).

### Import realm (apply git changes)

```bash
./scripts/import-keycloak-realm.sh
```

| Flag | Purpose |
|------|---------|
| `--strategy skip` (default) | Add new clients/roles; leave existing unchanged |
| `--strategy overwrite` | Replace clients/roles from JSON; existing users untouched |
| `--with-users [file]` | Import users with SKIP (never overwrites existing accounts) |

After `./scripts/ensure-oidc-secrets.sh --rotate`, run import with `--strategy overwrite`.

Run any script with `help` for full options, e.g. `./scripts/import-keycloak-realm.sh help`.

**Fallback:** copy a client secret from admin UI → `compose/.env` only if env-based import was skipped.

## Edge proxy (`glow-traefik`)

`glow-traefik` is the single HTTP entry on `${TRAEFIK_HTTP_PORT:-80}` (no TLS in local compose).

| Traffic | URL (port 80) |
|---------|----------------|
| Keycloak admin / OIDC from host | `http://localhost/auth/...` |
| Frontend UI | `http://localhost/` (Traefik catch-all; APIs and `/auth` take precedence) |
| Java APIs from host | `http://localhost/api/<service>/...` (e.g. `/api/restaurant`, `/api/user`) |

Postgres stays on `localhost:5432`. App containers are not published on `8080`–`8087` anymore.

Full routing table and “add a service” steps: [`traefik/README.md`](traefik/README.md).

### Keycloak hostname v2 (frontend + backchannel)

Keycloak 26.6 uses [hostname v2](https://www.keycloak.org/server/hostname):

- `KC_HOSTNAME` = `authBaseUrl` (e.g. `http://localhost/auth`) — public frontend for browser OIDC and token issuer
- `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` — services hitting `keycloak:8080/auth` get backchannel URLs on the Docker network
- `KC_HTTP_RELATIVE_PATH=/auth` — Keycloak serves under `/auth`; Traefik forwards without strip-prefix
- `KC_PROXY_HEADERS=xforwarded` — required behind Traefik

`QUARKUS_OIDC_AUTH_SERVER_URL` is `http://keycloak:8080/auth/realms/glow-realm`. Quarkus follows discovery; backchannel dynamic ensures `token_endpoint` / `jwks_uri` resolve inside Docker, not via `localhost`.

After changing Keycloak env, recreate Keycloak and affected services:

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

Use the same Quarkus env names on Deployments (ConfigMap / Secret). Service JARs only ship non-environment defaults (Liquibase, Hibernate, etc.).
