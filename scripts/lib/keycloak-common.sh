# Shared helpers for Keycloak export/import scripts.
# shellcheck shell=bash
set -euo pipefail

KEYCLOAK_COMMON_LOADED=1

KEYCLOAK_REALM="${KEYCLOAK_REALM:-glow-realm}"
KEYCLOAK_REALM_FILE="${KEYCLOAK_REALM_FILE:-${DEVOPS_ROOT}/keycloak/glow-realm-realm.json}"
KEYCLOAK_USERS_FILE="${KEYCLOAK_USERS_FILE:-${DEVOPS_ROOT}/keycloak/glow-realm-users-0.json}"
KEYCLOAK_CLIENT_SECRETS_FILE="${KEYCLOAK_CLIENT_SECRETS_FILE:-${DEVOPS_ROOT}/keycloak/client-secrets.yaml}"
KEYCLOAK_LIB_DIR="${KEYCLOAK_LIB_DIR:-${DEVOPS_ROOT}/scripts/lib}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

_KC_SCRIPT_TMPDIR=""

cleanup_script_tmpdir() {
  if [[ -n "${_KC_SCRIPT_TMPDIR}" && -d "${_KC_SCRIPT_TMPDIR}" ]]; then
    rm -rf "${_KC_SCRIPT_TMPDIR}"
  fi
  _KC_SCRIPT_TMPDIR=""
}

make_script_tmpdir() {
  cleanup_script_tmpdir
  _KC_SCRIPT_TMPDIR="$(mktemp -d)"
  trap cleanup_script_tmpdir EXIT
}

show_help_if_requested() {
  local usage_fn="$1"
  shift
  if ((${#@} == 0)); then
    return 0
  fi
  case "$1" in
    help | --help | -h)
      "${usage_fn}"
      exit 0
      ;;
  esac
}

require_compose_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing compose env file: ${ENV_FILE}" >&2
    echo "Create it from the template:" >&2
    echo "  cp ${ENV_EXAMPLE} ${ENV_FILE}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  local missing=()
  [[ -z "${POSTGRES_USER:-}" ]] && missing+=("POSTGRES_USER")
  [[ -z "${POSTGRES_PASSWORD:-}" ]] && missing+=("POSTGRES_PASSWORD")
  [[ -z "${REGISTRY_PREFIX:-}" ]] && missing+=("REGISTRY_PREFIX")
  [[ -z "${IMAGE_TAG:-}" ]] && missing+=("IMAGE_TAG")

  if ((${#missing[@]} > 0)); then
    echo "Missing or empty variables in ${ENV_FILE}: ${missing[*]}" >&2
    exit 1
  fi

  export POSTGRES_USER POSTGRES_PASSWORD REGISTRY_PREFIX IMAGE_TAG
}

compose_cmd() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Please start Docker and try again." >&2
    exit 1
  fi
}

require_client_secrets_file() {
  if [[ ! -f "${KEYCLOAK_CLIENT_SECRETS_FILE}" ]]; then
    echo "Missing client secrets config: ${KEYCLOAK_CLIENT_SECRETS_FILE}" >&2
    exit 1
  fi
}

keycloak_http_ready() {
  # Keycloak 26.x image has no curl; /health/ready is often disabled. /realms/master returns 200 when up.
  docker exec glow-keycloak /bin/bash -c \
    'exec 3<>/dev/tcp/127.0.0.1/8080 && printf "GET /realms/master HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3 && head -1 <&3 | grep -q "200"' \
    >/dev/null 2>&1
}

wait_for_keycloak() {
  local attempt=0
  local max_attempts=120

  if ! docker ps --format '{{.Names}}' | grep -qx 'glow-keycloak'; then
    echo "Container glow-keycloak is not running." >&2
    exit 1
  fi

  echo "Waiting for Keycloak to be ready..."
  until keycloak_http_ready; do
    attempt=$((attempt + 1))
    if ((attempt > max_attempts)); then
      echo "Keycloak did not become ready in time (checked /realms/master)." >&2
      exit 1
    fi
    if ((attempt % 15 == 0)); then
      echo "Still waiting for Keycloak... (attempt ${attempt}/${max_attempts})"
    fi
    sleep 2
  done
  echo "Keycloak is ready."
}

kcadm_config_credentials() {
  docker exec glow-keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server "http://localhost:8080" \
    --realm master \
    --user "${KEYCLOAK_ADMIN_USER}" \
    --password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null
}

realm_exists() {
  kcadm_config_credentials
  docker exec glow-keycloak /opt/keycloak/bin/kcadm.sh get "realms/${KEYCLOAK_REALM}" >/dev/null 2>&1
}

substitute_env_placeholders() {
  local input_file="$1"
  local output_file="$2"
  python3 - "${ENV_FILE}" "${input_file}" "${output_file}" <<'PY'
import re
import sys
from pathlib import Path

env_path, input_path, output_path = sys.argv[1:4]
env = {}
for line in Path(env_path).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    env[key.strip()] = value.strip()

text = Path(input_path).read_text(encoding="utf-8")

def repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name not in env:
        # Leave Keycloak built-in templates (e.g. ${client_account}) unchanged.
        return match.group(0)
    return env[name]

resolved = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, text)
Path(output_path).write_text(resolved, encoding="utf-8")
PY
}

post_process_realm_export() {
  local input_file="$1"
  local output_file="$2"
  python3 - "${KEYCLOAK_LIB_DIR}" "${KEYCLOAK_CLIENT_SECRETS_FILE}" "${input_file}" "${output_file}" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

lib_dir, secrets_path, input_path, output_path = sys.argv[1:5]
loader = Path(lib_dir) / "load_client_secrets.py"
spec = importlib.util.spec_from_file_location("load_client_secrets", loader)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)
client_to_env = mod.load_client_secrets(Path(secrets_path))

with open(input_path, encoding="utf-8") as fh:
    data = json.load(fh)

data.pop("users", None)

for client in data.get("clients", []):
    client_id = client.get("clientId")
    if client_id in client_to_env and not client.get("publicClient", False):
        client["secret"] = f"${{{client_to_env[client_id]}}}"

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

build_partial_import_payload() {
  local realm_file="$1"
  local strategy="$2"
  local with_users="$3"
  local users_file="$4"
  local output_file="$5"
  local users_only="${6:-false}"
  python3 - "${realm_file}" "${strategy}" "${with_users}" "${users_file}" "${output_file}" "${users_only}" <<'PY'
import json
import sys
from pathlib import Path

realm_file, strategy, with_users, users_file, output_file, users_only = sys.argv[1:7]
with open(realm_file, encoding="utf-8") as fh:
    realm = json.load(fh)

payload = {"ifResourceExists": strategy.upper()}

if users_only != "true":
    for key in ("clients", "groups", "identityProviders", "identityProviderMappers"):
        if key in realm and realm[key]:
            payload[key] = realm[key]

    roles = realm.get("roles")
    if roles:
        payload["roles"] = roles

if with_users == "true":
    users_path = Path(users_file)
    if not users_path.is_file():
        raise SystemExit(f"Users file not found: {users_path}")
    with open(users_path, encoding="utf-8") as fh:
        users = json.load(fh)
    if isinstance(users, dict) and "users" in users:
        users = users["users"]
    if users:
        payload["users"] = users

with open(output_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

strip_users_from_realm_file() {
  local input_file="$1"
  local output_file="$2"
  python3 - "${input_file}" "${output_file}" <<'PY'
import json
import sys

input_path, output_path = sys.argv[1:3]
with open(input_path, encoding="utf-8") as fh:
    data = json.load(fh)
data.pop("users", None)
with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}
