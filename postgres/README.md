# Local Postgres (`glow-postgres`)

One Postgres instance for local development. **glow-devops** ensures empty databases exist; Keycloak and each Java service own their schema.

## Two ways databases get created

| Situation | What runs |
|-----------|-----------|
| **Brand-new** Postgres volume (first `docker compose up` for `glow-postgres`) | `postgres/init/00-databases.sql` via `docker-entrypoint-initdb.d` (once only) |
| **Existing** volume, new name in `databases.txt` | `./scripts/ensure-postgres.sh` (or `./scripts/compose-up.sh`, which calls it) |

`./gradlew glowBuild` in a service repo **does not** run init SQL or `ensure-databases.sh`. After adding a database, run **`./scripts/ensure-postgres.sh`** from `glow-devops` before (or right after) your first `glowBuild`.

## Database list

When adding a service, update **both**:

1. `postgres/databases.txt` — one name per line (used by `ensure-postgres.sh`)
2. `postgres/init/00-databases.sql` — `CREATE DATABASE <name>;` (first empty volume only)

## Add a database for a new service

1. Add the name to `databases.txt` and a `CREATE DATABASE` line to `init/00-databases.sql`.
2. Add a service block in `compose/docker-compose.yml` (JDBC URL, ports, `depends_on: glow-postgres`, Keycloak if needed).
3. Run **`./scripts/ensure-postgres.sh`** (creates the DB on an existing Postgres instance).
4. From the service repo: **`./gradlew glowBuild`** (builds a **local** image; no registry image required).

Requires `compose/.env` (see `compose/.env.example`).

## New service, no registry image yet

`glowBuild` tags the image as `…-service:local` and passes it to compose. You do **not** need a remote image.

- Use **`glowBuild`** for the app container (not `compose-up.sh` with default `pull`, which would fail if the image is not in the registry).
- Use **`ensure-postgres.sh`** for Postgres + databases.
- Keycloak starts automatically when compose brings up your service (`depends_on: keycloak`), as long as the `keycloak` database already exists (it is in `databases.txt` by default).

Optional: start shared infra once without pulling your new service:

```bash
./scripts/compose-up.sh --no-pull keycloak
# or full stack without the new service
```
