#!/usr/bin/env bash
set -euo pipefail

: "${STAMP:?set STAMP to the dump directory timestamp under /opt/backups/leaperone-migration}"
DE_DIR="/opt/backups/leaperone-migration/${STAMP}"

ssh root@de.leaper.one "set -euo pipefail
cd '${DE_DIR}'
sha256sum -c SHA256SUMS
cd /opt/apps/postgres/production
PGPASS=\$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)
docker exec -i -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('dokilove_db', 'multipost_db') AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS dokilove_db;
DROP DATABASE IF EXISTS multipost_db;
CREATE DATABASE dokilove_db WITH TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';
CREATE DATABASE multipost_db WITH TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';
SQL
docker exec -i postgres-production pg_restore -U postgres -d dokilove_db --no-owner --no-acl < '${DE_DIR}/dokilove_db.dump'
docker exec -i postgres-production pg_restore -U postgres -d multipost_db --no-owner --no-acl < '${DE_DIR}/multipost_db.dump'
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d dokilove_db -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d postgres -P pager=off -c \"SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname IN ('dokilove_db','multipost_db') ORDER BY datname;\"
"
