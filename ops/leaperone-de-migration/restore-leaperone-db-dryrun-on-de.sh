#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

: "${STAMP:?set STAMP to the dump directory timestamp under ${DE_BACKUP_BASE}}"

DRYRUN_DB="${DRYRUN_DB:-leaperone_db_dryrun}"
DE_DIR="${DE_BACKUP_BASE}/${STAMP}"

ssh root@"${DE_HOST}" "set -euo pipefail
cd '${DE_DIR}'
sha256sum -c SHA256SUMS
cd /opt/apps/postgres/production
PGPASS=\$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)
docker exec -i -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${DRYRUN_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DRYRUN_DB};
CREATE DATABASE ${DRYRUN_DB}
  WITH TEMPLATE template0
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.UTF-8'
  LC_CTYPE 'en_US.UTF-8';
SQL
docker exec -i postgres-production pg_restore -U postgres -d '${DRYRUN_DB}' --no-owner --no-acl < '${DE_DIR}/${DB_NAME}.dump'
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d '${DRYRUN_DB}' -P pager=off -c \"SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1,2;\"
"
