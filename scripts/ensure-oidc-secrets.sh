#!/usr/bin/env bash
# Create or rotate OIDC client secrets in an environment secrets file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/env-files.sh
source "${SCRIPT_DIR}/lib/env-files.sh"

# shellcheck source=lib/keycloak-common.sh
source "${SCRIPT_DIR}/lib/keycloak-common.sh"

KEYCLOAK_CLIENT_SECRETS_FILE="${DEVOPS_ROOT}/keycloak/client-secrets.yaml"
KEYCLOAK_LIB_DIR="${DEVOPS_ROOT}/scripts/lib"

GLOW_ENV="local"
do_rotate=false
push_k8s=false

usage() {
  cat <<'EOF'
Usage: ./scripts/ensure-oidc-secrets.sh [options]

Ensures every GLOW_*_OIDC_CLIENT_SECRET listed in keycloak/client-secrets.yaml
exists in the target env file. Missing, empty, or *placeholder* values are generated.

Options:
  --env <local|production>   Target env file (default: local → compose/.env)
  --rotate                           Regenerate all mapped OIDC secrets
  --push-k8s                         After updating the file, apply to the cluster
                                     (requires kubectl + KUBECONFIG; production only)
  help                               Show this help (--help, -h)

Env files (interim — future: GitLab CI / vault):
  local       compose/.env
  production  helm/environments/production/secrets.env

After --rotate on a running Keycloak:
  ./scripts/import-keycloak-realm.sh --strategy overwrite   (Compose / local)
  ./scripts/k8s.sh secrets restart <env>                    (K8s pods)

Secret values are never printed.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || { echo "Missing value for --env" >&2; exit 1; }
        GLOW_ENV="$2"
        shift 2
        ;;
      --rotate)
        do_rotate=true
        shift
        ;;
      --push-k8s)
        push_k8s=true
        shift
        ;;
      help | --help | -h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

ensure_env_file() {
  if [[ -f "${GLOW_SECRETS_FILE}" ]]; then
    return 0
  fi

  if [[ "${GLOW_ENV}" == "local" && -f "${GLOW_SECRETS_EXAMPLE}" ]]; then
    cp "${GLOW_SECRETS_EXAMPLE}" "${GLOW_SECRETS_FILE}"
    echo "Created ${GLOW_SECRETS_FILE} from template."
    return 0
  fi

  echo "Missing ${GLOW_SECRETS_FILE}" >&2
  if [[ -f "${GLOW_SECRETS_EXAMPLE}" ]]; then
    echo "  ./scripts/k8s.sh secrets init ${GLOW_ENV}" >&2
    echo "  or: cp ${GLOW_SECRETS_EXAMPLE} ${GLOW_SECRETS_FILE}" >&2
  fi
  exit 1
}

main() {
  parse_args "$@"

  resolve_glow_env "${GLOW_ENV}"

  if [[ ! -f "${KEYCLOAK_CLIENT_SECRETS_FILE}" ]]; then
    echo "Missing ${KEYCLOAK_CLIENT_SECRETS_FILE}" >&2
    exit 1
  fi

  ensure_env_file

  local rotate_flag="false"
  [[ "${do_rotate}" == "true" ]] && rotate_flag="true"

  python3 - "${KEYCLOAK_LIB_DIR}" "${KEYCLOAK_CLIENT_SECRETS_FILE}" "${GLOW_SECRETS_FILE}" "${rotate_flag}" <<'PY'
import importlib.util
import secrets
import sys
from pathlib import Path

lib_dir, secrets_path, env_path, rotate_flag = sys.argv[1:5]
rotate = rotate_flag == "true"

loader = Path(lib_dir) / "load_client_secrets.py"
spec = importlib.util.spec_from_file_location("load_client_secrets", loader)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)
env_vars = mod.load_env_var_names(Path(secrets_path))

path = Path(env_path)
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
present = {}
for idx, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
    key, _, value = stripped.partition("=")
    present[key.strip()] = idx

created = []
rotated = []

for var in env_vars:
    current = None
    if var in present:
        line = lines[present[var]]
        current = line.strip().partition("=")[2].strip()

    needs_new = rotate or current is None or current == "" or current == "*placeholder*" or current == "change-me"
    if not needs_new:
        continue

    new_secret = secrets.token_hex(32)
    new_line = f"{var}={new_secret}\n"
    if var in present:
        lines[present[var]] = new_line
        rotated.append(var)
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] = lines[-1] + "\n"
        lines.append(new_line)
        created.append(var)

path.write_text("".join(lines), encoding="utf-8")

for var in created:
    print(f"Created secret: {var}")
for var in rotated:
    print(f"Rotated secret: {var}")
if not created and not rotated:
    print("All OIDC client secrets are already set.")
PY

  if [[ "${push_k8s}" == "true" ]]; then
    # shellcheck source=lib/k8s-apply-secrets.sh
    source "${SCRIPT_DIR}/lib/k8s-apply-secrets.sh"
    k8s_apply_cluster_secrets "${GLOW_ENV}"
  fi
}

main "$@"
