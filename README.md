# glow-devops

The GLOW DevOps repository provides the shared infrastructure and deployment configuration for the GLOW microservices platform. It includes **Docker Compose** for local development, **Kubernetes/Helm** configurations for deployment, **Keycloak** authentication setup, **PostgreSQL** configuration, and **GitLab CI/CD** tooling.

Technologies:
* Docker & Docker Compose
* Kubernetes & Helm
* Keycloak / OIDC
* PostgreSQL
* GitLab CI/CD

## Docker Compose local stack

The local compose setup is in `compose/docker-compose.yml` and the preferred startup helper is `scripts/compose-up.sh`.

### Default workflow

```bash
./scripts/compose-up.sh
```

By default this script runs:
1. `docker compose down`
2. `docker compose pull`
3. `docker compose up`

### Registry authentication (required for private images)

Before running the compose stack, authenticate Docker to the on-prem GitLab Container Registry.

1. Create a GitLab Personal Access Token with `read_registry` scope.
2. Login to the registry with your GitLab username and use the token as password:
   ```bash
   docker login registry.gitlab.au.dk -u <your-gitlab-username>
   ```
3. When prompted for password, paste the access token.

You can validate access with:
```bash
docker pull registry.gitlab.au.dk/backend-architecture-and-scalability/glow-restaurant-service:latest
```

### Useful overrides

- Pin a specific remote tag for all services in one run:
  ```bash
  ./scripts/compose-up.sh --tag 1234
  ```
- Override one service image with a locally built Gradle image:
  ```bash
  ./scripts/compose-up.sh --image glow-restaurant-service:local glow-restaurant
  ```
- Restart **one** service without stopping others (no `compose down`):
  ```bash
  ./scripts/compose-up.sh glow-user
  ```
  Passing a service name only pulls/starts that service; `glow-restaurant` and the rest stay running.

Create **`glow-devops/compose/.env`** before running the stack (required):

```bash
cp compose/.env.example compose/.env
```

Set variables from `compose/.env.example` (Postgres, registry, edge proxy, OIDC secrets). `./scripts/compose-up.sh` exits if `.env` is missing. **Connection strings and secrets live in `compose/docker-compose.yml` + `.env`**, not in service repos — see [`compose/README.md`](compose/README.md).

### Naming (compose vs registry)

- **Compose service key:** short name, e.g. `glow-restaurant`
- **Registry image repo:** same name + `-service`, e.g. `glow-restaurant-service` (matches GitLab `CI_REGISTRY_IMAGE`)

### Local development with `glowBuild` (service repos)

| Step | Command | Purpose |
|------|---------|---------|
| Shared env | `cp compose/.env.example compose/.env` (set `GLOW_USER_OIDC_CLIENT_SECRET`, etc.) | Required for compose and Gradle |
| Postgres + DBs | `./scripts/ensure-postgres.sh` | Start Postgres; create DBs from `postgres/databases.txt` |
| Run your service | `cd <service-repo> && ./gradlew glowBuild` | `quarkusBuild` → local Docker image → compose up **this** service only |

`glowBuild` does **not** run Postgres init or `ensure-databases.sh`. After you add a database or service to compose, run **`./scripts/ensure-postgres.sh`** once (safe to repeat).

**One-time full stack** (optional; pulls registry images, runs `down`):

```bash
export GLOW_HOME="/path/to/code"
cp compose/.env.example compose/.env
./scripts/compose-up.sh
```

**Day-to-day in e.g. `glow-restaurant`:**

```bash
cd glow-restaurant
./gradlew glowBuild
```

Uses a **local** image (`glow-restaurant-service:local`) — no registry image required. Restaurant API: **`http://localhost/api/restaurant/`** (via `glow-traefik`). Requires `com.glow.local-env` and `GLOW_HOME`; see `glow-gradle-plugin` README.

### New service (compose + DB defined, image not in registry yet)

1. Update `postgres/databases.txt` and `postgres/init/00-databases.sql`, then add the service in `compose/docker-compose.yml`.
2. `./scripts/ensure-postgres.sh` — creates the new database on existing Postgres.
3. `cd <new-service-repo> && ./gradlew glowBuild` — builds and starts only that service; Compose starts Postgres/Keycloak via `depends_on` if needed.

Do **not** rely on `./scripts/compose-up.sh <new-service>` with default **pull** until the image exists in the registry. Use `glowBuild` or `compose-up.sh --no-pull --image <name>:local <service>`.

### Postgres helpers

- **`./scripts/ensure-postgres.sh`** — Postgres up + idempotent DB ensure (use with `glowBuild`).
- **`./scripts/compose-up.sh --postgres-only`** — same as `ensure-postgres.sh`.
- See `postgres/README.md` for adding databases and init vs ensure behavior.

## Kubernetes (Helm + k3d / university k3s)

Helm charts under [`helm/`](helm/) deploy the same stack as Compose on k3d (local) or the university Orbit cluster (production).

All Kubernetes commands go through **`./scripts/k8s.sh`** (secrets, deploy, local k3d, service dev). See [`k8s/README.md`](k8s/README.md) and [`helm/README.md`](helm/README.md).

**Windows:** `k8s.sh` is bash — use `bash ./scripts/k8s.sh ...` from PowerShell (Git for Windows) or run the bash blocks in Git Bash / WSL. See [helm/README.md](helm/README.md) for PowerShell examples.

**macOS / Linux (bash):**

```bash
export GLOW_HOME="/path/to/code"

# Local k3d (uses ~/.kube/glow-k3d.yaml — never glow-config.yaml)
./scripts/k8s.sh local setup && ./scripts/k8s.sh local deploy

# Orbit cluster (Orbit kubeconfig only in ~/.kube/glow-config.yaml)
export KUBECONFIG=~/.kube/glow-config.yaml
./scripts/k8s.sh secrets init production
./scripts/k8s.sh deploy production --bootstrap
```

**Windows (PowerShell):**

```powershell
$env:GLOW_HOME = "C:\path\to\code"

# Local k3d (uses %USERPROFILE%\.kube\glow-k3d.yaml — never glow-config.yaml)
bash ./scripts/k8s.sh local setup
bash ./scripts/k8s.sh local deploy

# Orbit cluster (Orbit kubeconfig only in %USERPROFILE%\.kube\glow-config.yaml)
$env:KUBECONFIG = "$env:USERPROFILE\.kube\glow-config.yaml"
bash ./scripts/k8s.sh secrets init production
bash ./scripts/k8s.sh deploy production --bootstrap
```

# Keycloak

## 1. Setting up Keycloak locally

Prerequisites differ slightly 
between Windows and macOS.

### Prerequisites

**Windows 11:**
- Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/)
- Ensure WSL 2 is enabled (Docker Desktop will prompt you if not)
- Use PowerShell or Windows Terminal for all commands

**macOS:**
- Install [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/)
- Use Terminal or iTerm2 for all commands

Once Docker Desktop is installed, make sure it is **running** before proceeding 
(you should see the Docker whale icon in your taskbar/menu bar).

### Steps

1. Clone the `glow-devops` repository and open a terminal in its root directory
2. Copy env and generate OIDC secrets:
```bash
   cp compose/.env.example compose/.env
   ./scripts/ensure-oidc-secrets.sh
```
3. Start the local stack (Keycloak + services):
```bash
   ./scripts/compose-up.sh
```
   Or Keycloak only:
```bash
   ./scripts/compose-up.sh keycloak
```
   Wait until you see `Keycloak 26.6 ... started` in the terminal output before 
   proceeding. First run will take longer as Docker pulls the image.

4. The realm, roles, and clients are imported from `keycloak/glow-realm-realm.json` on first boot – no manual admin UI configuration is needed.
5. Verify the setup by requesting a test token (see Section 3).

> **Note:** `glow-devops` contains shared infrastructure only. Each microservice 
> has its own repository and connects to this locally running Keycloak instance 
> during development.

## 2. Keycloak setup details

- **Image**: `quay.io/keycloak/keycloak:26.6`
- **Mode**: `start --import-realm` (local HTTP, no strict hostname; Postgres on `glow-postgres`, database `keycloak`)
- **Admin credentials**: `admin / admin` (local dev only, never used in production)
- **Realm**: `glow-realm`
- **Roles**: `CUSTOMER`, `COURIER`, `RESTAURANT_USER`, `SYSADMIN`
- **Clients**: `glow-frontend` (public), `glow-user-service` (confidential)
- **Realm config**: committed to `keycloak/glow-realm-realm.json`, auto-imported on 
  first startup via `--import-realm`; updates via `./scripts/import-keycloak-realm.sh`
- **OIDC secrets**: `compose/.env` (generate with `./scripts/ensure-oidc-secrets.sh`)

### Production (Orbit) contract

| Concern | Local | Production (Orbit) |
|---------|-------|---------------------|
| Secret storage | `compose/.env` | K8s Secret / GitLab protected CI variables (`GLOW_*_OIDC_CLIENT_SECRET`) |
| Keycloak env | `docker-compose.yml` | Deployment `envFrom` / secret refs |
| Realm config | `keycloak/glow-realm-realm.json` in git | Same file; CI runs `import-keycloak-realm.sh` |
| Keycloak image | `quay.io/keycloak/keycloak:26.6` | Same tag |
| Bootstrap | `--import-realm` or import script | `kc.sh import` on empty DB, or Operator `KeycloakRealmImport` with placeholders |
| Updates | `import-keycloak-realm.sh` (SKIP) | Same script; never `import --override` on live DB with real users |
| Rotation | `ensure-oidc-secrets.sh --rotate` + overwrite import | Update vault/CI secret → redeploy Keycloak → import overwrite |

Realm JSON never contains real secrets. User data in production is never wiped by import. See [`compose/README.md`](compose/README.md#keycloak) for export/import workflows.

## 3. Running Keycloak locally

Keycloak is available at **http://localhost/auth** (via `glow-traefik` on port 80). Run `./scripts/ensure-oidc-secrets.sh` before first start. The realm is imported from _keycloak/glow-realm-realm.json_. No manual admin UI configuration is needed after the initial setup.

Admin console: http://localhost/auth/admin (`admin / admin`)  
Token endpoint: `http://localhost/auth/realms/glow-realm/protocol/openid-connect/token`

Frontend UI: **http://localhost/** (`glow-ui` via Traefik catch-all). Java APIs use `/api/<service>` on the same host (e.g. `http://localhost/api/restaurant/`, `http://localhost/api/user/`). See [`compose/traefik/README.md`](compose/traefik/README.md).

After changing `glow-frontend` redirect URIs in the realm JSON, run `./scripts/import-keycloak-realm.sh --strategy overwrite`.

### Verifying the setup (Optional)

Request a token for the test user. Note the OS difference in curl usage:

**Windows (PowerShell):**
```powershell
curl.exe -X POST http://localhost/auth/realms/glow-realm/protocol/openid-connect/token `
  -H "Content-Type: application/x-www-form-urlencoded" `
  -d "grant_type=password" `
  -d "client_id=glow-frontend" `
  -d "username=testcustomer" `
  -d "password=test123"
```

**macOS (Terminal):**
```bash
curl -X POST http://localhost/auth/realms/glow-realm/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=glow-frontend" \
  -d "username=testcustomer" \
  -d "password=test123"
```

A successful response contains an `access_token` field. The token is a JWT with three 
parts separated by dots (`header.payload.signature`) – copy the **entire string** and 
paste it into [jwt.io](https://jwt.io) to inspect it. Under **Payload** you should see:
```json
"realm_access": {
  "roles": ["CUSTOMER"]
}
```

This confirms Keycloak is correctly issuing tokens with the right role assigned.

---
---

# Getting started

To make it easy for you to get started with GitLab, here's a list of recommended next steps.

Already a pro? Just edit this README.md and make it your own. Want to make it easy? [Use the template at the bottom](#editing-this-readme)!

## Add your files

* [Create](https://docs.gitlab.com/user/project/repository/web_editor/#create-a-file) or [upload](https://docs.gitlab.com/user/project/repository/web_editor/#upload-a-file) files
* [Add files using the command line](https://docs.gitlab.com/topics/git/add_files/#add-files-to-a-git-repository) or push an existing Git repository with the following command:

```
cd existing_repo
git remote add origin https://gitlab.au.dk/backend-architecture-and-scalability/glow-devops.git
git branch -M main
git push -uf origin main
```

## Integrate with your tools

* [Set up project integrations](https://gitlab.au.dk/backend-architecture-and-scalability/glow-devops/-/settings/integrations)

## Collaborate with your team

* [Invite team members and collaborators](https://docs.gitlab.com/user/project/members/)
* [Create a new merge request](https://docs.gitlab.com/user/project/merge_requests/creating_merge_requests/)
* [Automatically close issues from merge requests](https://docs.gitlab.com/user/project/issues/managing_issues/#closing-issues-automatically)
* [Enable merge request approvals](https://docs.gitlab.com/user/project/merge_requests/approvals/)
* [Set auto-merge](https://docs.gitlab.com/user/project/merge_requests/auto_merge/)

## Test and Deploy

Use the built-in continuous integration in GitLab.

* [Get started with GitLab CI/CD](https://docs.gitlab.com/ci/quick_start/)
* [Analyze your code for known vulnerabilities with Static Application Security Testing (SAST)](https://docs.gitlab.com/user/application_security/sast/)
* [Deploy to Kubernetes, Amazon EC2, or Amazon ECS using Auto Deploy](https://docs.gitlab.com/topics/autodevops/requirements/)
* [Use pull-based deployments for improved Kubernetes management](https://docs.gitlab.com/user/clusters/agent/)
* [Set up protected environments](https://docs.gitlab.com/ci/environments/protected_environments/)

***
