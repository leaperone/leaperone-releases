#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

tmp="$(mktemp)"
printf '[]\n' > "${tmp}"

add_route() {
  local zone="$1"
  local pattern="$2"
  local zid
  zid="$(zone_id "${zone}")"
  local response
  response="$(cf -X POST "${CF_API}/zones/${zid}/workers/routes" \
    -H "Content-Type: application/json" \
    --data "{\"pattern\":\"${pattern}\",\"script\":\"${MAINTENANCE_SCRIPT}\"}")"
  printf '%s\n' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["success"], d; print(d["result"]["id"])' >/dev/null
  python3 - "$tmp" "$zone" "$zid" "$pattern" "$response" <<'PY'
import json, sys
path, zone, zid, pattern, raw = sys.argv[1:]
state = json.load(open(path))
result = json.loads(raw)["result"]
state.append({"zone": zone, "zone_id": zid, "pattern": pattern, "route_id": result["id"]})
json.dump(state, open(path, "w"), indent=2)
PY
  echo "enabled maintenance route: ${pattern}"
}

add_route "doki.love" "doki.love/*"
add_route "doki.love" "www.doki.love/*"
add_route "multipost.app" "multipost.app/*"
add_route "multipost.app" "api.multipost.app/*"

mv "${tmp}" "${ROUTE_STATE_FILE}"
echo "route state written: ${ROUTE_STATE_FILE}"
