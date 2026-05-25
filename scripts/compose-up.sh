#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DEVOPS_ROOT}/compose/docker-compose.yml"

do_clean=true
do_clean_explicit=false
do_pull=true
postgres_only=false
image_tag=""
image_ref=""
services=()

usage() {
  cat <<'EOF'
Usage: ./scripts/compose-up.sh [options] [service ...]

Default behavior with no service arguments:
  1) Stop/remove the whole compose stack (docker compose down)
  2) Pull latest images
  3) Start Postgres and ensure databases from postgres/databases.txt
  4) Start all services from the compose file

With one or more service names (e.g. glow-user):
  - Does not run compose down (other services such as glow-restaurant keep running)
  - Pulls and starts only the listed services (+ Postgres ensure)

Options:
  --no-clean       Skip docker compose down (default when service names are passed)
  --clean          Run compose down before up (whole stack; only use with no service args)
  --no-pull        Skip docker compose pull
  --postgres-only  Only start Postgres and ensure databases (see scripts/ensure-postgres.sh)
  --tag <tag>      Set IMAGE_TAG for this command
  --image <ref>    Set SERVICE_IMAGE_REF (requires exactly one service)
  --help           Show this help

Examples:
  ./scripts/compose-up.sh
  ./scripts/compose-up.sh glow-restaurant
  ./scripts/compose-up.sh --postgres-only
  ./scripts/compose-up.sh --no-pull --image glow-restaurant-service:local glow-restaurant
  ./scripts/ensure-postgres.sh

Requires glow-devops/compose/.env (copy from compose/.env.example).
EOF
}

ENV_FILE="${DEVOPS_ROOT}/compose/.env"
ENV_EXAMPLE="${DEVOPS_ROOT}/compose/.env.example"

require_compose_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing compose env file: ${ENV_FILE}" >&2
    echo "Create it from the template:" >&2
    echo "  cp ${ENV_EXAMPLE} ${ENV_FILE}" >&2
    echo "Then set at least POSTGRES_USER, POSTGRES_PASSWORD, REGISTRY_PREFIX, and IMAGE_TAG." >&2
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

  if [[ -z "${GLOW_USER_OIDC_CLIENT_SECRET:-}" ]]; then
    echo "Warning: GLOW_USER_OIDC_CLIENT_SECRET is not set in ${ENV_FILE}. glow-user-service OIDC will fail." >&2
  fi

  if ((${#missing[@]} > 0)); then
    echo "Missing or empty variables in ${ENV_FILE}: ${missing[*]}" >&2
    exit 1
  fi

  export POSTGRES_USER POSTGRES_PASSWORD REGISTRY_PREFIX IMAGE_TAG
}

while (($#)); do
  case "$1" in
    --no-clean)
      do_clean=false
      do_clean_explicit=true
      shift
      ;;
    --clean)
      do_clean=true
      do_clean_explicit=true
      shift
      ;;
    --no-pull)
      do_pull=false
      shift
      ;;
    --postgres-only)
      postgres_only=true
      do_clean=false
      do_pull=false
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "Missing value for --tag"; exit 1; }
      image_tag="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "Missing value for --image"; exit 1; }
      image_ref="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      services+=("$1")
      shift
      ;;
  esac
done

# Targeting specific services: never tear down the full stack unless --clean was passed.
if ((${#services[@]} > 0)) && [[ "${do_clean_explicit}" == "false" ]]; then
  do_clean=false
fi

if ((${#services[@]} > 0)) && [[ "${do_clean}" == "true" ]]; then
  echo "Warning: compose down stops the entire stack, not only: ${services[*]}" >&2
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

require_compose_env

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Please start Docker and try again."
  exit 1
fi

if [[ -n "${image_ref}" ]]; then
  if ((${#services[@]} != 1)); then
    echo "--image requires exactly one service argument."
    exit 1
  fi
  export SERVICE_IMAGE_REF="${image_ref}"
fi

if [[ -n "${image_tag}" ]]; then
  export IMAGE_TAG="${image_tag}"
fi

compose_cmd=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
up_args=(up -d)

if [[ "${postgres_only}" == "true" ]]; then
  if ((${#services[@]} > 0)); then
    echo "--postgres-only does not take service arguments." >&2
    exit 1
  fi
  exec bash "${SCRIPT_DIR}/ensure-postgres.sh"
fi

if [[ "${do_clean}" == "true" ]]; then
  "${compose_cmd[@]}" down
fi

if [[ "${do_pull}" == "true" ]]; then
  if ((${#services[@]} == 0)); then
    "${compose_cmd[@]}" pull
  else
    "${compose_cmd[@]}" pull "${services[@]}"
  fi
fi

bash "${SCRIPT_DIR}/ensure-postgres.sh"

if ((${#services[@]} == 0)); then
  "${compose_cmd[@]}" "${up_args[@]}"
else
  "${compose_cmd[@]}" "${up_args[@]}" "${services[@]}"
fi
