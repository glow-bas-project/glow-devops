#!/usr/bin/env bash
# Export glow-realm from Keycloak DB to keycloak/glow-realm-realm.json (no users; env placeholders for secrets).
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
Usage: ./scripts/export-keycloak-realm.sh [options]

Exports realm glow-realm from the running Keycloak Postgres database.
Stops Keycloak briefly, runs kc.sh export (--users skip), post-processes JSON,
then restarts Keycloak.

Output: keycloak/glow-realm-realm.json (client secrets as ${ENV_VAR} placeholders)

Options:
  --include-users   Also export users to keycloak/glow-realm-users-0.json (optional seed file)
  --no-restart      Leave Keycloak stopped after export
  help              Show this help (--help, -h)

Prerequisites:
  - compose/.env configured
  - Docker running; glow-postgres available

Examples:
  ./scripts/export-keycloak-realm.sh
  ./scripts/export-keycloak-realm.sh --include-users
EOF
}

include_users=false
do_restart=true

parse_args() {
  while (($#)); do
    case "$1" in
      --include-users)
        include_users=true
        shift
        ;;
      --no-restart)
        do_restart=false
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

main() {
  parse_args "$@"

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "Compose file not found: ${COMPOSE_FILE}" >&2
    exit 1
  fi

  require_compose_env
  require_docker

  if [[ ! -f "${KEYCLOAK_REALM_FILE}" ]] && [[ -f "${DEVOPS_ROOT}/keycloak/realm-export.json" ]]; then
    echo "Note: using legacy keycloak/realm-export.json path is deprecated; output goes to ${KEYCLOAK_REALM_FILE}" >&2
  fi

  bash "${SCRIPT_DIR}/ensure-postgres.sh"

  make_script_tmpdir
  local tmpdir="${_KC_SCRIPT_TMPDIR}"

  echo "Stopping keycloak..."
  compose_cmd stop keycloak

  echo "Exporting realm ${KEYCLOAK_REALM}..."
  compose_cmd run --rm --no-deps \
    -v "${tmpdir}:/tmp/keycloak-export" \
    keycloak export \
    --dir /tmp/keycloak-export \
    --realm "${KEYCLOAK_REALM}" \
    --users skip

  local exported="${tmpdir}/${KEYCLOAK_REALM}-realm.json"
  if [[ ! -f "${exported}" ]]; then
    echo "Export did not produce ${exported}" >&2
    exit 1
  fi

  local processed="${tmpdir}/processed-realm.json"
  post_process_realm_export "${exported}" "${processed}"

  local out_tmp="${KEYCLOAK_REALM_FILE}.tmp"
  mkdir -p "$(dirname "${KEYCLOAK_REALM_FILE}")"
  cp "${processed}" "${out_tmp}"
  mv "${out_tmp}" "${KEYCLOAK_REALM_FILE}"
  echo "Wrote ${KEYCLOAK_REALM_FILE}"

  if [[ "${include_users}" == "true" ]]; then
    echo "Exporting users (separate file)..."
    local user_tmpdir
    user_tmpdir="$(mktemp -d)"
    compose_cmd run --rm --no-deps \
      -v "${user_tmpdir}:/tmp/keycloak-export-users" \
      keycloak export \
      --dir /tmp/keycloak-export-users \
      --realm "${KEYCLOAK_REALM}" \
      --users same_file

    local users_exported="${user_tmpdir}/${KEYCLOAK_REALM}-users-0.json"
    if [[ -f "${users_exported}" ]]; then
      cp "${users_exported}" "${KEYCLOAK_USERS_FILE}"
      echo "Wrote ${KEYCLOAK_USERS_FILE}"
    else
      echo "Warning: user export file not found; realm may have no users." >&2
    fi
    rm -rf "${user_tmpdir}"
  fi

  if [[ "${do_restart}" == "true" ]]; then
    echo "Starting keycloak..."
    compose_cmd up -d keycloak
  else
    echo "Keycloak left stopped (--no-restart)."
  fi

  echo "Review changes: git diff keycloak/"

  cleanup_script_tmpdir
  trap - EXIT
}

main "$@"
