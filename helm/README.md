# GLOW on Kubernetes

Helm charts in this repo deploy the same application stack as [compose/docker-compose.yml](../compose/docker-compose.yml), but on Kubernetes instead of Docker Compose.

- **Local:** k3d cluster on your machine (`http://localhost:8880`)
- **University cluster (Orbit):** single production namespace on `project.orbit.au.dk` under `/alt-2026f01/`

Compose is still the default for everyday Docker-based development. Use Helm when you want to test or run the stack on k8s.

---

## Part 1 — Understand and run it

### What gets deployed

Each Helm release is a **full copy** of the stack in its own namespace:

| Component | Source |
|-----------|--------|
| PostgreSQL | Bitnami chart (`postgres` dependency) |
| Keycloak | Custom template — `quay.io/keycloak/keycloak:26.6` (same as Compose) |
| 7 Quarkus APIs | Custom templates in `helm/glow/templates/microservices.yaml` |
| Frontend UI | Local subchart `helm/charts/ui` |
| HTTP routing | **Local k3d:** Traefik Ingress → api-proxy. **Orbit:** Gateway API HTTPRoute → Envoy Gateway → api-proxy. Compose uses Traefik container. |

Images are pulled from `registry.gitlab.au.dk/backend-architecture-and-scalability/*` (same as Compose).

### Directory layout (what is what)

```
helm/
  README.md                     ← you are here
  glow/                         ← umbrella chart — this is what you install
    Chart.yaml                  ← declares Bitnami + ui dependencies
    Chart.lock                  ← pinned dependency versions
    values.yaml                 ← shared defaults for all environments
    charts/                     ← downloaded/packaged dependencies (after helm dependency update)
    files/glow-realm-realm.json ← symlink (not a copy) → keycloak/glow-realm-realm.json
    templates/
      microservices.yaml        ← all 7 Java services (Deployment + Service each)
      httproute.yaml            ← Gateway API routes (Orbit production)
      ingress.yaml              ← Traefik Ingress (local k3d only)
      api-proxy.yaml            ← in-cluster path stripping for UI + APIs
      configmap-realm.yaml      ← embeds realm JSON into ConfigMap glow-realm at deploy time
  charts/
    microservice/               ← reference template (not installed directly)
    ui/                         ← glow-ui Deployment + Service
  environments/
    local/values.yaml           ← localhost:8880, paths like Compose
    production/values.yaml      ← Orbit hostname + /alt-2026f01 path prefix + HTTPRoute
    orbit-resources.yaml        ← vCluster resource limits (Orbit + local k3d)

k8s/
  namespaces.yaml               ← glow-production (apply once on Orbit)

scripts/
  k8s.sh                        ← secrets, deploy, local k3d, service dev
  ensure-oidc-secrets.sh        ← OIDC generation (used by k8s.sh secrets)
  lib/                          ← implementation (k3d-local, k8s-apply-secrets, …)
```

**Rule of thumb:** edit `helm/glow/values.yaml` for stack-wide defaults; edit `helm/environments/<env>/values.yaml` for hostname, path prefix, and Keycloak public URLs. Never commit secrets — they live in `compose/.env` or `helm/environments/<env>/secrets.env` (gitignored).

**Keycloak realm file:** the only file you edit is [keycloak/glow-realm-realm.json](../keycloak/glow-realm-realm.json) (same as Compose). Helm can only bundle files inside the chart directory, so `helm/glow/files/glow-realm-realm.json` is a **symbolic link** to that path — not a duplicate copy. `templates/configmap-realm.yaml` reads it via `.Files.Get` and creates ConfigMap `glow-realm` when you run `helm upgrade`.

### Environments and URLs

| Where | Namespace | Host | UI | Keycloak | API example |
|-------|-----------|------|-----|----------|-------------|
| Local k3d | `glow-local` | `localhost:8880` | `/` | `/auth` | `/api/user/` |
| Production (Orbit) | `glow-production` | `project.orbit.au.dk` | `/alt-2026f01/` | `/alt-2026f01/auth` | `/alt-2026f01/api/user/` |

### Before you start

Assume **Docker**, **kubectl**, **Helm**, and **k3d** are already installed. One-time repo setup and registry login:

**macOS / Linux (bash):**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
docker login registry.gitlab.au.dk -u <gitlab-user>   # read_registry token

export GLOW_HOME="/path/to/parent/of/glow-devops"     # same as Gradle glowBuild; must contain glow-ui/
```

**Windows (PowerShell):** The `scripts/*.sh` helpers are bash — run them with **`bash ./scripts/...`** (Git for Windows) or use **Git Bash** / **WSL** with the bash blocks below.

```powershell
helm repo add bitnami https://charts.bitnami.com/bitnami; helm repo update
docker login registry.gitlab.au.dk -u <gitlab-user>

$env:GLOW_HOME = "C:\path\to\parent\of\glow-devops"   # same as Gradle glowBuild; must contain glow-ui\
```

Use **`http://localhost:8880`** in the browser (not `glow.local`) — the UI uses PKCE, which requires a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts). Browsers treat `http://localhost` as secure; plain HTTP on other hostnames is not.

### Scripts (`./scripts/k8s.sh`)

On **Windows**, prefix script calls with `bash` from PowerShell, or open **Git Bash** and use the bash forms below.

| Command | Purpose |
|---------|---------|
| `./scripts/k8s.sh local setup` | Create k3d cluster (built-in Traefik), namespace, secrets |
| `./scripts/k8s.sh local deploy` | Helm install/upgrade local stack |
| `./scripts/k8s.sh local wait` | Wait until all Deployments are Ready |
| `./scripts/k8s.sh local status` | Pods, services, Ingress |
| `./scripts/k8s.sh secrets init production` | Create `secrets.env`, push to Orbit cluster |
| `./scripts/k8s.sh deploy production --bootstrap` | First deploy to university cluster (live pod snapshots while waiting) |
| `./scripts/k8s.sh status production` | Pods, services, HTTPRoute on Orbit |
| `./scripts/k8s.sh wait production` | Block until all workloads Ready on Orbit |
| `./scripts/k8s.sh deploy production` | Upgrade production |
| `./scripts/k8s.sh dev glow-user` | Build one service locally, import into k3d |
| `./scripts/k8s.sh teardown production` | `helm uninstall` (keeps PVCs) |

Run `./scripts/k8s.sh help` (or `bash ./scripts/k8s.sh help` on Windows) for secrets rotate/restart/destroy and all options.

Optional env vars for registry secret creation: `GITLAB_REGISTRY_USER`, `GITLAB_REGISTRY_TOKEN`.

### Typical workflows

**First time on your laptop:**

**macOS / Linux (bash):**

```bash
cd "$GLOW_HOME/glow-devops"
cp compose/.env.example compose/.env
./scripts/ensure-oidc-secrets.sh

./scripts/k8s.sh local setup
./scripts/k8s.sh local deploy
```

**Windows (PowerShell):**

```powershell
Set-Location "$env:GLOW_HOME\glow-devops"
Copy-Item compose\.env.example compose\.env
bash ./scripts/ensure-oidc-secrets.sh

bash ./scripts/k8s.sh local setup
bash ./scripts/k8s.sh local deploy
```

**Check it works:**

| Check | URL |
|-------|-----|
| UI | http://localhost:8880/ |
| Keycloak realm | http://localhost:8880/auth/realms/glow-realm |
| User API | http://localhost:8880/api/user/q/health |

```bash
./scripts/k8s.sh local status
kubectl logs -n glow-local deploy/keycloak --tail=50
# or: kubectl logs -n glow-local -l app.kubernetes.io/name=keycloak --tail=50
```

```powershell
bash ./scripts/k8s.sh local status
kubectl logs -n glow-local deploy/keycloak --tail=50
```

**Develop one service on k3d (like `glowBuild` for Compose):**

**macOS / Linux (bash):**

```bash
export GLOW_HOME="/path/to/code"
./scripts/k8s.sh dev glow-user
# builds in glow-user-service repo, imports glow-user-service:local into k3d, redeploys only that pod
```

**Windows (PowerShell):**

```powershell
$env:GLOW_HOME = "C:\path\to\code"
bash ./scripts/k8s.sh dev glow-user
```

**University cluster:**

**macOS / Linux (bash):**

```bash
export KUBECONFIG=~/.kube/glow-config.yaml
kubectl apply -f k8s/namespaces.yaml

./scripts/k8s.sh secrets init production
./scripts/k8s.sh deploy production --bootstrap
```

**Windows (PowerShell):**

```powershell
$env:KUBECONFIG = "$env:USERPROFILE\.kube\glow-config.yaml"
kubectl apply -f k8s/namespaces.yaml

bash ./scripts/k8s.sh secrets init production
bash ./scripts/k8s.sh deploy production --bootstrap
```

**Manual helm (without scripts):**

**macOS / Linux (bash):**

```bash
cd helm/glow && helm dependency update && cd ../..

helm upgrade --install glow ./helm/glow \
  -f helm/glow/values.yaml \
  -f helm/environments/local/values.yaml \
  -f helm/environments/orbit-resources.yaml \
  -n glow-local --create-namespace --wait
```

**Windows (PowerShell):**

```powershell
Push-Location helm\glow; helm dependency update; Pop-Location

helm upgrade --install glow .\helm\glow `
  -f helm\glow\values.yaml `
  -f helm\environments\local\values.yaml `
  -f helm\environments\orbit-resources.yaml `
  -n glow-local --create-namespace --wait
```

### Secrets (short version)

Kubernetes needs a Secret named **`glow-secrets`** in each namespace with at least:

- `POSTGRES_PASSWORD`
- All `GLOW_*_OIDC_CLIENT_SECRET` keys (see [keycloak/client-secrets.yaml](../keycloak/client-secrets.yaml))

Generate locally with `./scripts/ensure-oidc-secrets.sh`, then `./scripts/k8s.sh secrets apply local` (Windows: prefix both with `bash`).

For production, secrets live in `helm/environments/production/secrets.env` (see [k8s/README.md](../k8s/README.md)); future: GitLab protected CI variables.

You also need **`gitlab-registry`** (docker-registry secret) so the cluster can pull private images — Set `GITLAB_REGISTRY_USER` / `GITLAB_REGISTRY_TOKEN` when running `./scripts/k8s.sh secrets apply`, or create it manually.

---

## Part 2 — How it works (detailed)

### Umbrella chart

Everything installs as one Helm release named `glow`.

`helm/glow/Chart.yaml` pulls in:

| Dependency | Alias | Role |
|------------|-------|------|
| `bitnami/postgresql` | `postgres` | Shared Postgres; Service name `glow-postgres` |
| `charts/ui` | `ui` | `glow-ui` frontend |

Keycloak is a **custom template** (`templates/keycloak.yaml`), not a subchart — same image and env as [compose/docker-compose.yml](../compose/docker-compose.yml).

The seven Quarkus services are **not** separate subchart instances. They are defined once in `values.yaml` under `microservices:` and rendered by `templates/microservices.yaml` in a loop. That keeps adding a service to one list instead of seven chart dependencies.

`helm/charts/microservice/` is a standalone reference chart only — the real logic lives in the umbrella templates.

### Values: how layers combine

Helm merges files in order (later overrides earlier):

```bash
-f helm/glow/values.yaml                    # shared: postgres, keycloak, service list, registry
-f helm/environments/local/values.yaml     # host, paths, Keycloak public URLs
```

Important `global:` keys:

| Key | Meaning |
|-----|---------|
| `registry` | GitLab registry prefix for Java/UI images |
| `imageTag` | Tag for all microservices and UI (override with `--set global.imageTag=1234`) |
| `edgeHost` | Host for Ingress (local k3d) or HTTPRoute hostnames (Orbit) |
| `pathPrefix` | Path prefix prepended to UI and API paths (e.g. `/alt-2026f01` on Orbit) |
| `authPath` | Keycloak HTTP path (e.g. `/alt-2026f01/auth`) |
| `authBaseUrl` | Public Keycloak URL — used as OIDC issuer in Quarkus |
| `secretsName` | K8s Secret for passwords (`glow-secrets`) |
| `imagePullSecrets` | Usually `gitlab-registry` |

Environment files set `global.authBaseUrl`, `global.authPath`, etc. The Keycloak template reads those for `KC_HOSTNAME` and `KC_HTTP_RELATIVE_PATH` (same contract as [compose/README.md](../compose/README.md#keycloak-hostname-v2-frontend--backchannel)).

### PostgreSQL (Bitnami)

Configured under `postgres:` in `values.yaml`:

- **`fullnameOverride: glow-postgres`** — stable DNS name; JDBC URLs use `jdbc:postgresql://glow-postgres:5432/<db>`
- **`primary.initdb.scripts`** — creates all databases on first PVC init (same list as [postgres/init/00-databases.sql](../postgres/init/00-databases.sql))
- **`auth.existingSecret: glow-secrets`** — password from `POSTGRES_PASSWORD` key (production); local can use the same

If you add a new service database, update both `postgres/init/00-databases.sql` (for Compose) **and** the init script block in `helm/glow/values.yaml`.

### Keycloak (official image, same as Compose)

`templates/keycloak.yaml` deploys a single-replica Deployment + Service `keycloak:8080`:

```yaml
keycloak:
  image:
    repository: quay.io/keycloak/keycloak
    tag: "26.6"
  database:
    host: glow-postgres
    name: keycloak
  # KC_HOSTNAME / KC_HTTP_RELATIVE_PATH come from global.authBaseUrl and global.authPath
```

Startup: `start --import-realm` with realm JSON mounted at `/opt/keycloak/data/import` (ConfigMap `glow-realm`).

Realm import:

1. Edit **[keycloak/glow-realm-realm.json](../keycloak/glow-realm-realm.json)** only — `helm/glow/files/glow-realm-realm.json` is a symlink to this file
2. **`templates/configmap-realm.yaml`** embeds the JSON into ConfigMap `glow-realm` on `helm upgrade`
3. Keycloak imports on first start (same as Compose)

OIDC client secrets are **not** in the JSON — placeholders like `${GLOW_USER_OIDC_CLIENT_SECRET}` are resolved from `keycloak.extraEnv` + `glow-secrets` (same as Compose).

Local admin password defaults to `admin`; production uses `KEYCLOAK_ADMIN_PASSWORD` from `glow-secrets` via `keycloak.auth.existingSecret`.

Internal service URL for Quarkus: `http://keycloak:8080/auth/...` (backchannel). Public issuer: `global.authBaseUrl/realms/glow-realm`.

After secret rotation, use [scripts/import-keycloak-realm.sh](../scripts/import-keycloak-realm.sh) — never full override import on production with real users.

### Microservices (custom templates)

Each entry in `microservices:` in `values.yaml` becomes a Deployment + ClusterIP Service named `glow-<name>` (e.g. `glow-user`).

Environment variables mirror Compose anchor `x-glow-java-env`:

| Variable | Source |
|----------|--------|
| `QUARKUS_OIDC_AUTH_SERVER_URL` | `http://keycloak:8080` + `authPath` + `/realms/glow-realm` |
| `QUARKUS_OIDC_TOKEN_ISSUER` | `global.authBaseUrl` + `/realms/glow-realm` |
| `QUARKUS_DATASOURCE_JDBC_URL` | `jdbc:postgresql://glow-postgres:5432/<database>` |
| `QUARKUS_OIDC_CLIENT_ID` / `CREDENTIALS_SECRET` | Per-service; restaurant has no OIDC client in Compose |

**Local dev override:** set `microservices[i].imageRef: glow-user-service:local` (done by `./scripts/k8s.sh dev`) to use a locally built image with `imagePullPolicy: Never` instead of the registry image.

### UI (glow-ui) — runtime config via `GLOW_*` env

The SPA reads **`/config.js`** at container start (written by `docker-entrypoint.sh` from env vars). One GitLab image works for compose, k3d, and production — no per-environment UI build.

| Variable | Purpose |
|----------|---------|
| `GLOW_APP_URL` | Post-login redirect base (must match browser origin) |
| `GLOW_KEYCLOAK_URL` | Keycloak base URL (no `/realms/...`) |
| `GLOW_KEYCLOAK_REALM` | `glow-realm` |
| `GLOW_KEYCLOAK_CLIENT_ID` | `glow-frontend` |
| `GLOW_PATH_PREFIX` | Router basename (e.g. `/alt-2026f01` on Orbit production) |

Sign-in uses **PKCE (S256)** via `keycloak-js`, which needs **`crypto.subtle`** — only available in a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts) (`https://…` or `http://localhost` / `127.0.0.1`, **not** `http://glow.local`).

#### Environment alignment

| Layer | Compose (port 80) | k3d local (port 8880) | Production (Orbit) |
|-------|-------------------|------------------------|---------------------|
| Browser UI | `http://localhost/` | `http://localhost:8880/` | `https://project.orbit.au.dk/alt-2026f01/` |
| `GLOW_APP_URL` | `compose/.env` | `global.publicOrigin` | `global.publicOrigin` |
| `GLOW_KEYCLOAK_URL` | `compose/.env` → `authBaseUrl` | `global.authBaseUrl` | `global.authBaseUrl` |
| `GLOW_PATH_PREFIX` | `compose/.env` (empty) | `global.pathPrefix` (empty) | `/alt-2026f01` |
| Helm `global.authBaseUrl` | `compose/.env` → `authBaseUrl` | `http://localhost:8880/auth` | `https://project.orbit.au.dk/alt-2026f01/auth` |
| Helm `global.publicOrigin` | `GLOW_APP_URL` | `http://localhost:8880` | `https://project.orbit.au.dk/alt-2026f01` |
| Keycloak `KC_HOSTNAME` | = `authBaseUrl` | from `global.authBaseUrl` | from env values |
| Quarkus `QUARKUS_OIDC_TOKEN_ISSUER` | `authBaseUrl/realms/glow-realm` | same pattern | same pattern |
| Realm `glow-frontend` redirects | `localhost`, `:5173` | + `:8880` | + `https://project.orbit.au.dk/alt-2026f01/*` |
| UI image | GitLab `:latest` | same registry image | same registry image |

Helm sets `GLOW_*` on the `glow-ui` Deployment from `global.*` (see `helm/charts/ui/templates/deployment.yaml`). Compose sets the same vars on the `glow-ui` service from `compose/.env`.

Backend secrets (`GLOW_*_OIDC_CLIENT_SECRET`, `POSTGRES_PASSWORD`) come from `compose/.env` / `glow-secrets` — same values across compose and k8s.

After changing `global.publicOrigin` / `global.authBaseUrl` in an environment values file, redeploy — the UI pod restarts and regenerates `/config.js`. No UI rebuild required.

### HTTP routing {#http-routing}

**Compose** uses the `glow-traefik` container — see [compose/traefik/README.md](../compose/traefik/README.md).

**Local k3d** uses k3d’s **built-in Traefik** and a standard `Ingress` (`templates/ingress.yaml`, enabled in `environments/local/values.yaml`). No extra gateway install — `setup` only creates the cluster and secrets.

**Orbit production** uses **Gateway API** `HTTPRoute` (`templates/httproute.yaml`) on the platform **Envoy Gateway**, plus the in-cluster **api-proxy** (`templates/api-proxy.yaml`):

- HTTPRoute: `{pathPrefix}/api` → api-proxy → strip `/api/<service>` → Quarkus
- HTTPRoute: `{pathPrefix}/auth` → Keycloak
- HTTPRoute: `{pathPrefix}/` → api-proxy → strip `{pathPrefix}` → UI nginx

Local paths are the same as Compose (`/`, `/api/...`, `/auth`) with no path prefix.

### University cluster

**Kubeconfig (two files — do not mix):**

| File | Purpose |
|------|---------|
| `~/.kube/glow-config.yaml` (Windows: `%USERPROFILE%\.kube\glow-config.yaml`) | **Orbit only** — download from Orbit portal |
| `~/.kube/glow-k3d.yaml` (Windows: `%USERPROFILE%\.kube\glow-k3d.yaml`) | **k3d only** — managed by `./scripts/k8s.sh local ...` |

Nothing in glow-devops writes to `glow-config.yaml`. If k3d credentials appear there, k3d was run manually while `KUBECONFIG` pointed at that file. Re-download the Orbit kubeconfig to fix it.

**macOS / Linux (bash):**

```bash
export KUBECONFIG=~/.kube/glow-config.yaml
kubectl cluster-info
kubectl apply -f k8s/namespaces.yaml
```

**Windows (PowerShell):**

```powershell
$env:KUBECONFIG = "$env:USERPROFILE\.kube\glow-config.yaml"
kubectl cluster-info
kubectl apply -f k8s/namespaces.yaml
```

**Deploy:** `./scripts/k8s.sh deploy production` uses `KUBECONFIG`, runs `helm dependency update`, and applies environment values. Use `--bootstrap` on first run. Use `--dry-run` to render only. While waiting, pod status is printed every 20s (same as local k3d). Use `./scripts/k8s.sh status|wait production` in another terminal or after `--no-wait`.

**Pin image versions:** `./scripts/k8s.sh deploy production --tag 1234` sets `global.imageTag`.

Production runs in an isolated namespace — own Postgres PVC, Keycloak DB, and secrets.

### Helm maintenance commands

```bash
# Refresh Bitnami / ui packages after Chart.yaml changes
cd helm/glow && helm dependency update

# Validate templates
helm lint ./helm/glow \
  -f helm/glow/values.yaml \
  -f helm/environments/local/values.yaml

# Render without applying
helm template glow ./helm/glow \
  -f helm/glow/values.yaml \
  -f helm/environments/local/values.yaml \
  -n glow-local > /tmp/glow.yaml
```

Bitnami versions are pinned in `Chart.yaml`. To upgrade:

```bash
helm search repo bitnami/postgresql --versions | head -3
# update Chart.yaml, then helm dependency update
```

### Adding a new microservice

1. Add DB to `postgres/databases.txt`, `postgres/init/00-databases.sql`, and `postgres:` init script in `helm/glow/values.yaml`
2. Add Compose service block (still needed for local Docker dev)
3. Add entry to `microservices:` in `helm/glow/values.yaml` (`name`, `image`, `database`, `apiPath`, `oidcClientId`, `oidcSecretKey`)
4. Add client to [keycloak/client-secrets.yaml](../keycloak/client-secrets.yaml) if confidential OIDC
5. Redeploy; HTTPRoute paths and `QUARKUS_HTTP_ROOT_PATH` are generated from the list automatically

### Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `ImagePullBackOff` on `keycloak-*` | Cluster cannot pull `quay.io/keycloak/keycloak:26.6` — check network / firewall |
| `ImagePullBackOff` on app pods | Missing `gitlab-registry` — `docker login registry.gitlab.au.dk` then `./scripts/k8s.sh local setup` or `secrets apply` |
| `helm upgrade` seems frozen | Wait for `--wait` to finish, or use `--no-wait` |
| Keycloak crash / import errors | Check `kubectl logs -n <ns> deploy/keycloak`; reset DB like [compose/README.md](../compose/README.md#keycloak) if first import failed |
| 404 on https://project.orbit.au.dk/alt-2026f01/ | Missing or unaccepted `HTTPRoute` — check `kubectl get httproute -n glow-production` and `kubectl describe httproute glow`. Orbit uses Envoy Gateway, not Ingress. In-cluster UI: `kubectl exec deploy/glow-api-proxy -- wget -qO- http://127.0.0.1:8080/alt-2026f01/` |
| `glow-user` / `keycloak` Pending, quota SyncError | `requests.memory` over 4Gi — redeploy after `orbit-resources.yaml` update; delete Pending pods |
| OIDC / 401 from APIs | `glow-secrets` OIDC values out of sync with Keycloak — run `import-keycloak-realm.sh --strategy overwrite` then redeploy |
| 404 on API paths | Check `kubectl get pods -n <ns>` includes `glow-api-proxy`; `curl http://localhost:8880/api/restaurant/restaurants` should return JSON |
| UI loads but Sign in fails / `Web Crypto API is not available` | Use **`http://localhost:8880`** (not `glow.local`). Check `kubectl exec` env on `glow-ui` pod (`GLOW_APP_URL`, `GLOW_KEYCLOAK_URL`). Update realm redirects if needed (`import-keycloak-realm.sh --strategy overwrite` or recreate Keycloak DB). |
| UI loads but blank / white page, 404 on `/assets/*` | Orbit only routes `/alt-2026f01/*` into your vCluster — root `/assets/` hits a platform default (404). Ensure `glow-ui` image is current (reads `pathPrefix` from `/config.js` for React Router). UI entrypoint prefixes asset URLs in `index.html` when `global.pathPrefix` is set. Test: `curl -I https://project.orbit.au.dk/alt-2026f01/assets/index-….js` |
| UI loads but auth/API wrong | `GLOW_*` env on `glow-ui` out of sync with `global.*` values — fix env values file and redeploy. Rebuild/push `glow-ui` from latest main if `/config.js` or router basename support is missing. |
| `helm dependency update` fails | Run `helm repo update`; remove broken repos from `helm repo list` |

### Relationship to Compose

| Concern | Compose | Kubernetes |
|---------|---------|------------|
| Config location | `compose/docker-compose.yml` + `compose/.env` | `helm/glow/values.yaml` + `helm/environments/*` + K8s Secrets |
| Edge routing | `glow-traefik` container | **Local k3d:** Traefik Ingress → api-proxy. **Orbit:** HTTPRoute → Envoy Gateway → api-proxy |
| Postgres host | `glow-postgres` | `glow-postgres` (same logical name) |
| Keycloak host (internal) | `keycloak:8080` | `keycloak:8080` |
| Local single-service dev | `./gradlew glowBuild` | `./scripts/k8s.sh dev glow-<service>` |
| UI auth URLs | `GLOW_*` env on `glow-ui` (from `compose/.env`) | `GLOW_*` env from `global.*` (runtime `/config.js`) |
| Secrets generation | `./scripts/ensure-oidc-secrets.sh` | `./scripts/k8s.sh secrets init|apply <env>` |

Service repos should **not** contain connection strings or secrets — same rule as Compose.
