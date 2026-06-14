# Shared env file paths for local compose and Kubernetes environments.
# Source from other scripts: source "${SCRIPT_DIR}/lib/env-files.sh"

resolve_glow_env() {
  local env="${1:-}"
  case "${env}" in
    local)
      GLOW_ENV="local"
      GLOW_SECRETS_FILE="${DEVOPS_ROOT}/compose/.env"
      GLOW_SECRETS_EXAMPLE="${DEVOPS_ROOT}/compose/.env.example"
      GLOW_K8S_NAMESPACE="glow-local"
      ;;
    production)
      GLOW_ENV="${env}"
      GLOW_SECRETS_FILE="${DEVOPS_ROOT}/helm/environments/${env}/secrets.env"
      GLOW_SECRETS_EXAMPLE="${DEVOPS_ROOT}/helm/environments/${env}/secrets.env.example"
      GLOW_K8S_NAMESPACE="glow-${env}"
      ;;
    *)
      echo "Unknown environment: ${env} (use local or production)" >&2
      return 1
      ;;
  esac
}

ensure_secrets_file() {
  local create_from_example="${1:-false}"
  if [[ -f "${GLOW_SECRETS_FILE}" ]]; then
    return 0
  fi

  if [[ "${create_from_example}" != "true" ]]; then
    echo "Missing secrets file: ${GLOW_SECRETS_FILE}" >&2
    if [[ -f "${GLOW_SECRETS_EXAMPLE}" ]]; then
      echo "  cp ${GLOW_SECRETS_EXAMPLE} ${GLOW_SECRETS_FILE}" >&2
    fi
    return 1
  fi

  if [[ ! -f "${GLOW_SECRETS_EXAMPLE}" ]]; then
    echo "Missing template: ${GLOW_SECRETS_EXAMPLE}" >&2
    return 1
  fi

  cp "${GLOW_SECRETS_EXAMPLE}" "${GLOW_SECRETS_FILE}"
  echo "Created ${GLOW_SECRETS_FILE} from template."
}

ensure_bootstrap_passwords() {
  python3 - "${GLOW_SECRETS_FILE}" <<'PY'
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
present = {}
for idx, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in stripped:
        continue
    key, _, value = stripped.partition("=")
    present[key.strip()] = (idx, value.strip())

placeholders = {"", "change-me", "change-me-production",
                "change-me-production-admin", "*placeholder*"}

def needs_new(key: str) -> bool:
    if key not in present:
        return True
    return present[key][1] in placeholders

updated = []
for key in ("POSTGRES_PASSWORD", "KEYCLOAK_ADMIN_PASSWORD"):
    if not needs_new(key):
        continue
    value = secrets.token_urlsafe(24)
    new_line = f"{key}={value}\n"
    if key in present:
        lines[present[key][0]] = new_line
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] = lines[-1] + "\n"
        lines.append(new_line)
    updated.append(key)

path.write_text("".join(lines), encoding="utf-8")
for key in updated:
    print(f"Generated bootstrap secret: {key}")
if not updated:
    print("Bootstrap passwords already set.")
PY
}
