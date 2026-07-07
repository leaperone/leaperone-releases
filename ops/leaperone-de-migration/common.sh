#!/usr/bin/env bash
set -euo pipefail

DE_HOST="${DE_HOST:-de.leaper.one}"
DE_IP="${DE_IP:-159.195.43.38}"
PVE_HOST="${PVE_HOST:-pve.leaper.one}"
DB_NAME="${DB_NAME:-leaperone_db}"
APP_ROLE="${APP_ROLE:-leaperone_app}"
DE_BACKUP_BASE="${DE_BACKUP_BASE:-/opt/backups/leaperone-migration}"
PVE_BACKUP_BASE="${PVE_BACKUP_BASE:-/root/db-migration}"
PVE_PG_PORT="${PVE_PG_PORT:-5433}"

cf_api() {
  local headers=(-H "Content-Type: application/json")
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    headers+=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
  elif [ -n "${CLOUDFLARE_EMAIL:-}" ] && [ -n "${CLOUDFLARE_GLOBAL_API_KEY:-}" ]; then
    headers+=(-H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}")
  else
    echo "set CLOUDFLARE_API_TOKEN or CLOUDFLARE_EMAIL+CLOUDFLARE_GLOBAL_API_KEY" >&2
    return 1
  fi
  curl -fsS "${headers[@]}" "$@"
}

zone_id() {
  local zone="$1"
  if [ "$zone" = "leaper.one" ] && [ -n "${CLOUDFLARE_ZONE_LEAPER_ONE:-}" ]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_LEAPER_ONE"
    return
  fi
  cf_api "https://api.cloudflare.com/client/v4/zones?name=${zone}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"])'
}
