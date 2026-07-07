#!/usr/bin/env bash
set -euo pipefail

STAMP="${STAMP:-$(date -u +%Y%m%d%H%M%S)}"
REMOTE_DIR="/root/db-migration/${STAMP}"
DE_DIR="/opt/backups/leaperone-migration/${STAMP}"

ssh root@pve.leaper.one "set -euo pipefail
mkdir -p '${REMOTE_DIR}'
pct exec 210 -- runuser -u postgres -- pg_dump -p 5433 -d dokilove_db -Fc -Z 9 --no-owner --no-acl > '${REMOTE_DIR}/dokilove_db.dump'
pct exec 210 -- runuser -u postgres -- pg_dump -p 5433 -d multipost_db -Fc -Z 9 --no-owner --no-acl > '${REMOTE_DIR}/multipost_db.dump'
cd '${REMOTE_DIR}'
sha256sum *.dump > SHA256SUMS
ssh root@de.leaper.one 'mkdir -p ${DE_DIR}'
scp -q '${REMOTE_DIR}'/* root@de.leaper.one:'${DE_DIR}/'
cat SHA256SUMS
"

echo "copied dumps to de.leaper.one:${DE_DIR}"
