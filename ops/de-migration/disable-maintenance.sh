#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

if [ ! -f "${ROUTE_STATE_FILE}" ]; then
  echo "no route state file at ${ROUTE_STATE_FILE}" >&2
  exit 1
fi

python3 - "${ROUTE_STATE_FILE}" <<'PY' | while IFS=$'\t' read -r zone_id route_id pattern; do
import json, sys
for item in json.load(open(sys.argv[1])):
    print(item["zone_id"], item["route_id"], item["pattern"], sep="\t")
PY
  cf -X DELETE "${CF_API}/zones/${zone_id}/workers/routes/${route_id}" >/dev/null
  echo "disabled maintenance route: ${pattern}"
done

rm -f "${ROUTE_STATE_FILE}"
