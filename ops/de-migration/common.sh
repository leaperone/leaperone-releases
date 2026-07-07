#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_EMAIL:?set CLOUDFLARE_EMAIL}"
: "${CLOUDFLARE_GLOBAL_API_KEY:?set CLOUDFLARE_GLOBAL_API_KEY}"

CF_API="https://api.cloudflare.com/client/v4"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-68a20037dba2d1b23dc1e159049e8efc}"
MAINTENANCE_SCRIPT="${MAINTENANCE_SCRIPT:-leaperone-maintenance}"
ROUTE_STATE_FILE="${ROUTE_STATE_FILE:-/tmp/leaperone-maintenance-routes.json}"
DE_IP="${DE_IP:-159.195.43.38}"

cf() {
  curl -fsS \
    -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
    -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" \
    "$@"
}

zone_id() {
  local zone="$1"
  cf "${CF_API}/zones?name=${zone}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"])'
}
