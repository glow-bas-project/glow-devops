# Used by scripts/compose-up.sh only (not mounted into postgres init; use init/00-databases.sql there).
set -eu

PGHOST="${PGHOST:-}"
PGUSER="${PGUSER:-glow}"
DB_LIST="${DB_LIST:-/databases.txt}"

if [ -z "${PGPASSWORD:-}" ]; then
  echo "PGPASSWORD is not set."
  exit 1
fi

if [ -n "${PGHOST}" ]; then
  until pg_isready -h "${PGHOST}" -U "${PGUSER}" -d postgres >/dev/null 2>&1; do
    echo "Waiting for Postgres at ${PGHOST}..."
    sleep 1
  done
else
  until pg_isready -U "${PGUSER}" -d postgres >/dev/null 2>&1; do
    echo "Waiting for local Postgres..."
    sleep 1
  done
fi

while IFS= read -r line || [ -n "${line}" ]; do
  db=$(printf '%s' "${line}" | sed 's/#.*//' | tr -d '[:space:]')
  [ -z "${db}" ] && continue

  if [ -n "${PGHOST}" ]; then
    exists=$(psql -h "${PGHOST}" -U "${PGUSER}" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${db}'")
    if [ "${exists}" = "1" ]; then
      echo "Database already exists: ${db}"
    else
      echo "Creating database: ${db}"
      psql -h "${PGHOST}" -U "${PGUSER}" -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE \"${db}\";"
    fi
  else
    exists=$(psql -U "${PGUSER}" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname = '${db}'")
    if [ "${exists}" = "1" ]; then
      echo "Database already exists: ${db}"
    else
      echo "Creating database: ${db}"
      psql -U "${PGUSER}" -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE \"${db}\";"
    fi
  fi
done < "${DB_LIST}"

echo "Database ensure complete."
