#!/usr/bin/env bash
# Start glow-postgres (if needed) and create any databases listed in postgres/databases.txt.
# Safe to run repeatedly. Does not pull images or start app services.
#
# Use when:
#   - You added a name to databases.txt / init SQL and only run ./gradlew glowBuild
#   - Postgres is already running but a new database was added to the list
#
# Does not replace first-time init on an empty volume (postgres/init/*.sql still runs once).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVOPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${DEVOPS_ROOT}/compose/docker-compose.yml"
ENV_FILE="${DEVOPS_ROOT}/compose/.env"
ENV_EXAMPLE="${DEVOPS_ROOT}/compose/.env.example"

usage() {
  cat <<'EOF'
Usage: ./scripts/ensure-postgres.sh

Ensures:
  1) glow-postgres is up and healthy
  2) Every database in postgres/databases.txt exists (idempotent CREATE)

Does not run compose down, pull, or start Keycloak/app services.
Pair with ./gradlew glowBuild in a service repo for day-to-day dev.

Requires compose/.env (copy from compose/.env.example).
EOF
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

wait_for_postgres() {
  local attempt=0
  until docker exec glow-postgres pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if ((attempt > 60)); then
      echo "Postgres did not become ready in time." >&2
      exit 1
    fi
    sleep 1
  done
}

ensure_postgres_databases() {
  docker run --rm --network glow-local \
    -e PGHOST=glow-postgres \
    -e PGUSER="${POSTGRES_USER}" \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    -e DB_LIST=/databases.txt \
    -v "${DEVOPS_ROOT}/postgres/ensure-databases.sh:/ensure-databases.sh:ro" \
    -v "${DEVOPS_ROOT}/postgres/databases.txt:/databases.txt:ro" \
    postgres:16-alpine \
    /bin/sh /ensure-databases.sh
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if (($# > 0)); then
  echo "Unknown argument: $1" >&2
  usage
  exit 1
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

require_compose_env

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not reachable. Please start Docker and try again." >&2
  exit 1
fi

compose_cmd=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")

echo "Starting glow-postgres (if not already running)..."
"${compose_cmd[@]}" up -d glow-postgres
wait_for_postgres
ensure_postgres_databases
echo "Postgres and databases are ready."
