#!/usr/bin/env bash
# Create or rotate OIDC client secrets in compose/.env (source of truth for Keycloak + services).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEVOPS_ROOT}/compose/.env"
ENV_EXAMPLE="${DEVOPS_ROOT}/compose/.env.example"

# shellcheck source=lib/keycloak-common.sh
source "${SCRIPT_DIR}/lib/keycloak-common.sh"

KEYCLOAK_CLIENT_SECRETS_FILE="${DEVOPS_ROOT}/keycloak/client-secrets.yaml"
KEYCLOAK_LIB_DIR="${DEVOPS_ROOT}/scripts/lib"

usage() {
  cat <<'EOF'
Usage: ./scripts/ensure-oidc-secrets.sh [options]

Ensures every GLOW_*_OIDC_CLIENT_SECRET listed in keycloak/client-secrets.yaml
exists in compose/.env. Missing, empty, or *placeholder* values are generated.

Options:
  --rotate   Regenerate all mapped secrets (replaces existing values)
  help       Show this help (--help, -h)

After --rotate, run:
  ./scripts/import-keycloak-realm.sh --strategy overwrite

Requires compose/.env (copy from compose/.env.example if missing).
Secret values are never printed.
EOF
}

do_rotate=false

parse_args() {
  while (($#)); do
    case "$1" in
      --rotate)
        do_rotate=true
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
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
      cp "${ENV_EXAMPLE}" "${ENV_FILE}"
      echo "Created ${ENV_FILE} from template."
    else
      echo "Missing ${ENV_FILE} and ${ENV_EXAMPLE}" >&2
      exit 1
    fi
  fi
}

main() {
  parse_args "$@"

  if [[ ! -f "${KEYCLOAK_CLIENT_SECRETS_FILE}" ]]; then
    echo "Missing ${KEYCLOAK_CLIENT_SECRETS_FILE}" >&2
    exit 1
  fi

  ensure_env_file

  local rotate_flag="false"
  [[ "${do_rotate}" == "true" ]] && rotate_flag="true"

  python3 - "${KEYCLOAK_LIB_DIR}" "${KEYCLOAK_CLIENT_SECRETS_FILE}" "${ENV_FILE}" "${rotate_flag}" <<'PY'
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

    needs_new = rotate or current is None or current == "" or current == "*placeholder*"
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
}

main "$@"
