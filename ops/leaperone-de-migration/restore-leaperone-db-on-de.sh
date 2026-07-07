#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

: "${STAMP:?set STAMP to the dump directory timestamp under ${DE_BACKUP_BASE}}"
: "${LEAPERONE_DB_APP_PASSWORD:?set LEAPERONE_DB_APP_PASSWORD}"
: "${CONFIRM_RESTORE_LEAPERONE_DB:?set CONFIRM_RESTORE_LEAPERONE_DB=restore-leaperone-db}"

if [ "${CONFIRM_RESTORE_LEAPERONE_DB}" != "restore-leaperone-db" ]; then
  echo "Refusing restore: CONFIRM_RESTORE_LEAPERONE_DB must equal restore-leaperone-db" >&2
  exit 1
fi

DE_DIR="${DE_BACKUP_BASE}/${STAMP}"

{
  cat <<REMOTE_HEAD
set -euo pipefail
read -r APP_PASSWORD
REMOTE_HEAD
  printf '%s\n' "${LEAPERONE_DB_APP_PASSWORD}"
  cat <<REMOTE
DE_DIR='${DE_DIR}'
DB_NAME='${DB_NAME}'
APP_ROLE='${APP_ROLE}'
cd "\${DE_DIR}"
sha256sum -c SHA256SUMS
cd /opt/apps/postgres/production
PGPASS="\$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)"
docker exec -i -e PGPASSWORD="\${PGPASS}" postgres-production psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v app_password="\${APP_PASSWORD}" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'leaperone_db' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS leaperone_db;
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'leaperone_app') THEN
    CREATE ROLE leaperone_app LOGIN;
  END IF;
END
\$\$;
ALTER ROLE leaperone_app LOGIN PASSWORD :'app_password';
CREATE DATABASE leaperone_db
  WITH OWNER leaperone_app
  TEMPLATE template0
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.UTF-8'
  LC_CTYPE 'en_US.UTF-8';
SQL
docker exec -i postgres-production pg_restore -U postgres --role="\${APP_ROLE}" -d "\${DB_NAME}" --no-owner --no-acl < "\${DE_DIR}/\${DB_NAME}.dump"
docker exec -i -e PGPASSWORD="\${PGPASS}" postgres-production psql -U postgres -d "\${DB_NAME}" -v ON_ERROR_STOP=1 <<'SQL'
GRANT CONNECT ON DATABASE leaperone_db TO leaperone_app;
GRANT USAGE ON SCHEMA public, drizzle TO leaperone_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, drizzle TO leaperone_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public, drizzle TO leaperone_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO leaperone_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO leaperone_app;
SQL
docker exec -e PGPASSWORD="\${PGPASS}" postgres-production psql -U postgres -d postgres -P pager=off -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datname = 'leaperone_db';"
REMOTE
} | ssh root@"${DE_HOST}" 'bash -s'
