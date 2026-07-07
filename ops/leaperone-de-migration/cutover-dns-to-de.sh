#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

update_a_record() {
  local zone="$1"
  local name="$2"
  local content="$3"
  local zid
  zid="$(zone_id "${zone}")"
  local record
  record="$(cf_api "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records?type=A&name=${name}")"
  local rid proxied ttl
  rid="$(printf '%s' "${record}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"])')"
  proxied="$(printf '%s' "${record}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["result"][0].get("proxied", True)).lower())')"
  ttl="$(printf '%s' "${record}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0].get("ttl", 1))')"
  cf_api -X PUT "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records/${rid}" \
    --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${content}\",\"ttl\":${ttl},\"proxied\":${proxied}}" \
    >/dev/null
  echo "updated ${name} -> ${content}"
}

update_a_record "leaper.one" "leaper.one" "${DE_IP}"
update_a_record "leaper.one" "api.leaper.one" "${DE_IP}"
