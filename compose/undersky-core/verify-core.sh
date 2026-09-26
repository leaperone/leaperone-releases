#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ $# == 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || { echo 'A full expected source SHA is required' >&2; exit 1; }
expected_sha="$1"
# shellcheck disable=SC1091
. ./.env
for endpoint in "http://127.0.0.1:${WWW_PORT}/api/health" "http://127.0.0.1:${DASHBOARD_PORT}/api/ready" "http://127.0.0.1:${API_PORT}/ready"; do
  curl --fail --silent --show-error --max-time 10 "$endpoint" >/dev/null
done
for component in www dashboard api; do
  revision="$(docker inspect "undersky-${component}-${DEPLOY_ENV:-production}" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$revision" == "$expected_sha" ]] || { echo "ERROR: $component image revision mismatch" >&2; exit 1; }
done
curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:${API_PORT}/health" |
  python3 -c 'import json,sys; x=json.load(sys.stdin); assert x.get("release")==sys.argv[1], "API release mismatch"; assert x.get("workers")=={"image":False,"video":False}, "Unexpected active worker"' "$expected_sha"
echo "UnderSky core readiness accepted for $expected_sha"
