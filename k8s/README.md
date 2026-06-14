# Kubernetes cluster resources

This folder holds cluster-level manifests that are **not** part of the Helm release itself.

| File | Purpose |
|------|---------|
| [namespaces.yaml](namespaces.yaml) | Creates `glow-production` on the university cluster |

Charts, values, and routing: **[helm/README.md](../helm/README.md)**.

## `./scripts/k8s.sh`

All Kubernetes workflows use **[`scripts/k8s.sh`](../scripts/k8s.sh)** — secrets, deploy, local k3d, and single-service dev. Run `./scripts/k8s.sh help` for the full command list.

**Windows:** `k8s.sh` is a bash script. From PowerShell, run `bash ./scripts/k8s.sh ...` (Git for Windows) or use **Git Bash** / **WSL** with the bash examples below. Set env vars with `$env:NAME = "value"`.

### Orbit URL (project.orbit.au.dk)

| Environment | Namespace | UI |
|-------------|-----------|-----|
| Production | `glow-production` | https://project.orbit.au.dk/alt-2026f01/ |

### Production first deploy

**Kubeconfig:** Orbit vCluster only in `~/.kube/glow-config.yaml` (Windows: `%USERPROFILE%\.kube\glow-config.yaml`). k3d uses `~/.kube/glow-k3d.yaml` via `./scripts/k8s.sh local` — never point `KUBECONFIG` at `glow-config.yaml` when running k3d.

**macOS / Linux (bash):**

```bash
export KUBECONFIG=~/.kube/glow-config.yaml
docker login registry.gitlab.au.dk -u <gitlab-user>

./scripts/k8s.sh secrets init production
./scripts/k8s.sh deploy production --bootstrap
```

**Windows (PowerShell):**

```powershell
$env:KUBECONFIG = "$env:USERPROFILE\.kube\glow-config.yaml"
docker login registry.gitlab.au.dk -u <gitlab-user>

bash ./scripts/k8s.sh secrets init production
bash ./scripts/k8s.sh deploy production --bootstrap
```

Local k3d test (built-in Traefik; no Envoy Gateway install):

**macOS / Linux (bash):**

```bash
./scripts/k8s.sh local destroy   # if you had an older Envoy-based cluster
./scripts/k8s.sh local setup && ./scripts/k8s.sh local deploy
```

**Windows (PowerShell):**

```powershell
bash ./scripts/k8s.sh local destroy   # if you had an older Envoy-based cluster
bash ./scripts/k8s.sh local setup
bash ./scripts/k8s.sh local deploy
```

Monitor Orbit deploy (another terminal or after `--no-wait`):

**macOS / Linux (bash):**

```bash
./scripts/k8s.sh status production
./scripts/k8s.sh wait production
./scripts/k8s.sh logs production glow-restaurant
```

**Windows (PowerShell):**

```powershell
bash ./scripts/k8s.sh status production
bash ./scripts/k8s.sh wait production
bash ./scripts/k8s.sh logs production glow-restaurant
```

### Secrets (interim: `secrets.env` on disk)

| Command | Purpose |
|---------|---------|
| `secrets init production` | Create file, generate values, push to cluster |
| `secrets apply production` | Push file to cluster |
| `secrets rotate production` | New OIDC secrets + push |
| `secrets restart production` | Restart pods after secret change |

**Future:** GitLab CI variables / vault — same `k8s.sh` commands, different secret source.

### Lifecycle

**macOS / Linux (bash):**

```bash
./scripts/k8s.sh teardown production
./scripts/k8s.sh destroy production --confirm
```

**Windows (PowerShell):**

```powershell
bash ./scripts/k8s.sh teardown production
bash ./scripts/k8s.sh destroy production --confirm
```

### Local k3d

**macOS / Linux (bash):**

```bash
./scripts/k8s.sh local setup
./scripts/k8s.sh local deploy
export GLOW_HOME=/path/to/code && ./scripts/k8s.sh dev glow-user
```

**Windows (PowerShell):**

```powershell
bash ./scripts/k8s.sh local setup
bash ./scripts/k8s.sh local deploy
$env:GLOW_HOME = "C:\path\to\code"
bash ./scripts/k8s.sh dev glow-user
```

| Command | Effect |
|---------|--------|
| `local undeploy` | `helm uninstall glow` (keeps namespace + k3d cluster) |
| `local destroy` | Delete the entire k3d cluster |
| `destroy local --confirm` | Delete only the `glow-local` namespace (keeps k3d cluster) |
