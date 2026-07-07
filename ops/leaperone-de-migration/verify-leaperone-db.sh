#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

echo "==> PVE source summary"
ssh root@"${PVE_HOST}" "pct exec 210 -- runuser -u postgres -- psql -p '${PVE_PG_PORT}' -d '${DB_NAME}' -P pager=off -c \"
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY schemaname, relname;
\""

echo "==> DE target summary"
ssh root@"${DE_HOST}" "set -euo pipefail
cd /opt/apps/postgres/production
PGPASS=\$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d '${DB_NAME}' -P pager=off -c \"
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY schemaname, relname;
\"
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d '${DB_NAME}' -P pager=off -c \"
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('public','drizzle') AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
\"
"
