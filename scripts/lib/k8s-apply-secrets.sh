# Apply glow-secrets + gitlab-registry to a cluster namespace.
# Source after env-files.sh (uses DEVOPS_ROOT, resolve_glow_env).

k8s_ensure_oidc_in_file() {
  local env_name="$1"
  local env_file="$2"

  if [[ ! -f "${env_file}" ]]; then
    echo "Missing env file: ${env_file}" >&2
    resolve_glow_env "${env_name}" 2>/dev/null || true
    if [[ -f "${GLOW_SECRETS_EXAMPLE:-}" ]]; then
      echo "  ./scripts/k8s.sh secrets init ${env_name}" >&2
    fi
    return 1
  fi

  local missing_oidc=false
  while IFS= read -r var; do
    [[ -n "${var}" ]] || continue
    if ! grep -q "^${var}=" "${env_file}"; then
      missing_oidc=true
      continue
    fi
    local val
    val="$(grep "^${var}=" "${env_file}" | head -1 | cut -d= -f2-)"
    if [[ -z "${val}" || "${val}" == "*placeholder*" || "${val}" == "change-me" ]]; then
      missing_oidc=true
    fi
  done < <(python3 - "${DEVOPS_ROOT}/keycloak/client-secrets.yaml" <<'PY'
import sys, yaml
from pathlib import Path
data = yaml.safe_load(Path(sys.argv[1]).read_text())
for env_var in data.get("clients", {}).values():
    print(env_var)
PY
)

  if [[ "${missing_oidc}" == true ]]; then
    echo "Generating missing OIDC secrets in ${env_file}..." >&2
    "${DEVOPS_ROOT}/scripts/ensure-oidc-secrets.sh" --env "${env_name}"
  fi
}

k8s_create_glow_secrets() {
  local namespace="$1"
  local env_file="$2"
  local tmp
  tmp="$(mktemp)"

  grep -E '^(POSTGRES_PASSWORD|KEYCLOAK_ADMIN_PASSWORD|GLOW_.*_OIDC_CLIENT_SECRET)=' "${env_file}" > "${tmp}"

  if ! grep -q '^POSTGRES_PASSWORD=' "${tmp}"; then
    echo "POSTGRES_PASSWORD missing in ${env_file}" >&2
    rm -f "${tmp}"
    return 1
  fi

  kubectl create secret generic glow-secrets \
    --from-env-file="${tmp}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | kubectl apply -f -

  rm -f "${tmp}"
  echo "Applied glow-secrets in namespace ${namespace}"
}

k8s_resolve_gitlab_registry_credentials() {
  if [[ -n "${GITLAB_REGISTRY_USER:-}" && -n "${GITLAB_REGISTRY_TOKEN:-}" ]]; then
    printf '%s\n' "${GITLAB_REGISTRY_USER}" "${GITLAB_REGISTRY_TOKEN}"
    return 0
  fi

  python3 - <<'PY'
import base64
import json
import subprocess
import sys
from pathlib import Path

REGISTRY = "registry.gitlab.au.dk"
REGISTRY_HTTPS = f"https://{REGISTRY}"


def emit(user: str, secret: str) -> None:
    print(user)
    print(secret)
    sys.exit(0)


cfg_path = Path.home() / ".docker" / "config.json"
if not cfg_path.exists():
    sys.exit(1)

data = json.loads(cfg_path.read_text())

for key in (REGISTRY, REGISTRY_HTTPS):
    auth = data.get("auths", {}).get(key, {}).get("auth")
    if auth:
        user, password = base64.b64decode(auth).decode().split(":", 1)
        emit(user, password)

helper_name = data.get("credsStore")
if not helper_name:
    helper_name = (data.get("credHelpers") or {}).get(REGISTRY)
    if helper_name:
        helper_name = helper_name.removeprefix("docker-credential-")

if helper_name:
    helper = f"docker-credential-{helper_name}"
    for url in (REGISTRY_HTTPS, REGISTRY):
        try:
            proc = subprocess.run(
                [helper, "get"],
                input=f"{url}\n",
                text=True,
                capture_output=True,
                check=True,
            )
            cred = json.loads(proc.stdout)
            emit(cred["Username"], cred["Secret"])
        except (subprocess.CalledProcessError, KeyError, json.JSONDecodeError, FileNotFoundError):
            continue

sys.exit(1)
PY
}

k8s_create_registry_secret() {
  local namespace="$1"
  local creds user token

  if ! creds="$(k8s_resolve_gitlab_registry_credentials 2>/dev/null)"; then
    cat >&2 <<'EOF'
Could not resolve GitLab registry credentials for kubernetes secret gitlab-registry.

Docker Desktop stores login in the credential helper (not config.json). Ensure you are logged in:
  docker login registry.gitlab.au.dk -u <gitlab-username>

Or set explicitly:
  export GITLAB_REGISTRY_USER=<gitlab-username>
  export GITLAB_REGISTRY_TOKEN=<personal-access-token with read_registry>
EOF
    return 1
  fi

  user="$(printf '%s\n' "${creds}" | sed -n '1p')"
  token="$(printf '%s\n' "${creds}" | sed -n '2p')"

  if [[ -z "${user}" || -z "${token}" ]]; then
    echo "Resolved empty GitLab registry credentials" >&2
    return 1
  fi

  echo "Using GitLab registry credentials for user: ${user}" >&2

  kubectl create secret docker-registry gitlab-registry \
    --docker-server=registry.gitlab.au.dk \
    --docker-username="${user}" \
    --docker-password="${token}" \
    -n "${namespace}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "Applied gitlab-registry in namespace ${namespace}"
}

# Push secrets from env file to cluster. Args: env [namespace]
k8s_apply_cluster_secrets() {
  local env="$1"
  local namespace="${2:-}"
  local compose_env="${DEVOPS_ROOT}/compose/.env"

  resolve_glow_env "${env}"
  namespace="${namespace:-${GLOW_K8S_NAMESPACE}}"

  local source_env="${compose_env}"
  if [[ -f "${GLOW_SECRETS_FILE}" ]]; then
    source_env="${GLOW_SECRETS_FILE}"
  elif [[ "${env}" != "local" ]]; then
    echo "Missing ${GLOW_SECRETS_FILE}" >&2
    echo "  ./scripts/k8s.sh secrets init ${env}" >&2
    return 1
  elif [[ ! -f "${source_env}" ]]; then
    echo "Missing ${source_env}" >&2
    echo "  ./scripts/k8s.sh secrets init local" >&2
    return 1
  fi

  if [[ "${env}" == "production" ]]; then
    if ! grep -q '^KEYCLOAK_ADMIN_PASSWORD=' "${source_env}"; then
      echo "KEYCLOAK_ADMIN_PASSWORD missing in ${source_env}" >&2
      echo "  ./scripts/k8s.sh secrets init ${env}" >&2
      return 1
    fi
  fi

  k8s_ensure_oidc_in_file "${env}" "${source_env}"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
  k8s_create_glow_secrets "${namespace}" "${source_env}"
  k8s_create_registry_secret "${namespace}"
}
