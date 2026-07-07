#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

STAMP="${STAMP:-$(date -u +%Y%m%d%H%M%S)}"
REMOTE_DIR="${PVE_BACKUP_BASE}/leaperone-${STAMP}"
DE_DIR="${DE_BACKUP_BASE}/${STAMP}"

ssh root@"${PVE_HOST}" "set -euo pipefail
mkdir -p '${REMOTE_DIR}'
pct exec 210 -- runuser -u postgres -- pg_dump -p '${PVE_PG_PORT}' -d '${DB_NAME}' -Fc -Z 9 --no-owner --no-acl > '${REMOTE_DIR}/${DB_NAME}.dump'
cd '${REMOTE_DIR}'
sha256sum '${DB_NAME}.dump' > SHA256SUMS
ssh root@'${DE_HOST}' 'mkdir -p ${DE_DIR}'
scp -q '${REMOTE_DIR}'/* root@'${DE_HOST}':'${DE_DIR}/'
ls -lh
cat SHA256SUMS
"

echo "copied dump to ${DE_HOST}:${DE_DIR}"
echo "STAMP=${STAMP}"
