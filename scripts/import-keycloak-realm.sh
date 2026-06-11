#!/usr/bin/env bash
# Import glow-realm: bootstrap via kc.sh import, or safe partial import when realm exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DEVOPS_ROOT}/compose/docker-compose.yml"
ENV_FILE="${DEVOPS_ROOT}/compose/.env"
ENV_EXAMPLE="${DEVOPS_ROOT}/compose/.env.example"

# shellcheck source=lib/keycloak-common.sh
source "${SCRIPT_DIR}/lib/keycloak-common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/import-keycloak-realm.sh [options]

Imports keycloak/glow-realm-realm.json into Keycloak.

  - Realm absent: bootstrap import (kc.sh import, Keycloak stopped). Env placeholders
    in the JSON are resolved from compose/.env via the Keycloak container.
  - Realm present: partial import via Admin API (Keycloak running). Existing users
    are never removed or modified unless you pass --with-users (always SKIP for users).

Options:
  --strategy skip|overwrite   Conflict policy for clients/roles/groups (default: skip)
  --with-users [file]         Also import users from file (default: glow-realm-users-0.json)
  help                        Show this help (--help, -h)

Examples:
  ./scripts/import-keycloak-realm.sh
  ./scripts/import-keycloak-realm.sh --strategy overwrite
  ./scripts/import-keycloak-realm.sh --with-users
  ./scripts/import-keycloak-realm.sh --with-users keycloak/dev-users.json

After ./scripts/ensure-oidc-secrets.sh --rotate:
  ./scripts/import-keycloak-realm.sh --strategy overwrite
EOF
}

strategy="skip"
with_users=false
users_file="${KEYCLOAK_USERS_FILE}"

parse_args() {
  while (($#)); do
    case "$1" in
      --strategy)
        [[ $# -ge 2 ]] || { echo "Missing value for --strategy" >&2; exit 1; }
        strategy="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --with-users)
        with_users=true
        if [[ $# -ge 2 && "$2" != --* ]]; then
          users_file="$2"
          shift
        fi
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

  case "${strategy}" in
    skip | overwrite) ;;
    *)
      echo "Invalid --strategy: ${strategy} (use skip or overwrite)" >&2
      exit 1
      ;;
  esac
}

bootstrap_import() {
  local import_dir="${1}"
  echo "Bootstrap import: realm ${KEYCLOAK_REALM} does not exist."

  compose_cmd stop keycloak

  compose_cmd run --rm --no-deps \
    -v "${import_dir}:/tmp/keycloak-import" \
    keycloak import \
    --dir /tmp/keycloak-import \
    --realm "${KEYCLOAK_REALM}"

  echo "Starting keycloak..."
  compose_cmd up -d keycloak
  wait_for_keycloak
  echo "Bootstrap import complete."
}

partial_import() {
  local payload_raw="${1}"
  local payload_resolved="${2}"

  substitute_env_placeholders "${payload_raw}" "${payload_resolved}"

  echo "Partial import (${strategy}, users stripped unless --with-users)..."
  wait_for_keycloak
  kcadm_config_credentials

  docker exec -i glow-keycloak /opt/keycloak/bin/kcadm.sh create "partialImport" \
    -r "${KEYCLOAK_REALM}" \
    -f - < "${payload_resolved}"

  echo "Partial import complete."
}

main() {
  parse_args "$@"

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "Compose file not found: ${COMPOSE_FILE}" >&2
    exit 1
  fi

  if [[ ! -f "${KEYCLOAK_REALM_FILE}" ]]; then
    echo "Realm file not found: ${KEYCLOAK_REALM_FILE}" >&2
    exit 1
  fi

  require_compose_env
  require_docker
  bash "${SCRIPT_DIR}/ensure-postgres.sh"

  make_script_tmpdir
  local tmpdir="${_KC_SCRIPT_TMPDIR}"

  local payload_raw="${tmpdir}/partial-import-raw.json"
  build_partial_import_payload \
    "${KEYCLOAK_REALM_FILE}" \
    "${strategy}" \
    "false" \
    "${users_file}" \
    "${payload_raw}"

  compose_cmd up -d keycloak
  wait_for_keycloak

  if realm_exists; then
    local payload_resolved="${tmpdir}/partial-import-resolved.json"
    partial_import "${payload_raw}" "${payload_resolved}"

    if [[ "${with_users}" == "true" ]]; then
      local users_raw="${tmpdir}/partial-import-users-raw.json"
      build_partial_import_payload \
        "${KEYCLOAK_REALM_FILE}" \
        "skip" \
        "true" \
        "${users_file}" \
        "${users_raw}" \
        "true"
      local users_resolved="${tmpdir}/partial-import-users-resolved.json"
      echo "Importing users (SKIP — existing users are not modified)..."
      partial_import "${users_raw}" "${users_resolved}"
    fi
  else
    local import_dir="${tmpdir}/import-dir"
    local realm_copy="${import_dir}/${KEYCLOAK_REALM}-realm.json"
    mkdir -p "${import_dir}"
    strip_users_from_realm_file "${KEYCLOAK_REALM_FILE}" "${realm_copy}"
    bootstrap_import "${import_dir}"
  fi

  cleanup_script_tmpdir
  trap - EXIT
}

main "$@"
