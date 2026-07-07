#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

echo "==> DE host"
ssh root@"${DE_HOST}" "set -euo pipefail
hostname
docker network inspect leaperone-prod >/dev/null
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'postgres-production|NAMES'
ss -ltnp | grep -E ':9800|:9801' || true
df -hT / /opt/apps
"

echo "==> PVE source database"
ssh root@"${PVE_HOST}" "set -euo pipefail
pct status 210
pct exec 210 -- runuser -u postgres -- psql -p '${PVE_PG_PORT}' -d '${DB_NAME}' -P pager=off -c 'SELECT current_database(), version();'
pct exec 210 -- runuser -u postgres -- psql -p '${PVE_PG_PORT}' -d '${DB_NAME}' -P pager=off -c \"SELECT schemaname, relname FROM pg_stat_user_tables ORDER BY 1,2;\"
"

echo "==> GitHub secrets by name"
gh secret list -R leaperone/leaperone-releases | grep -E 'DE_APP_|LEAPERONE_DE_DATABASE_URL|SENTRY_AUTH_TOKEN|ALIYUN_DOCKER_' || true
