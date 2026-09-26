#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -s .previous-compose.yml ]] || fail ".previous-compose.yml is missing; no rollback target exists"
[[ -s .previous-images.env ]] || fail ".previous-images.env is missing"
docker compose -f .previous-compose.yml config --quiet
docker compose -f .previous-compose.yml pull
docker compose -f .previous-compose.yml up -d --wait --wait-timeout 180
# shellcheck disable=SC1091
. ./.previous-images.env
previous_sha="${API_IMAGE_REF#*:api-}"; previous_sha="${previous_sha%@*}"
./verify-core.sh "$previous_sha"
cp .previous-images.env .images.env
cp .previous-compose.yml .current-compose.yml
echo "UnderSky core rollback restored the previous resolved Compose model; Nginx was not changed"
