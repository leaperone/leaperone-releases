#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -s .previous-compose.yml ]] || fail ".previous-compose.yml is missing; no rollback target exists"
docker compose -f .previous-compose.yml config --quiet
docker compose -f .previous-compose.yml pull
docker compose -f .previous-compose.yml up -d --wait --wait-timeout 180
if [[ -s .previous-images.env ]]; then cp .previous-images.env .images.env; fi
echo "UnderSky core rollback restored the previous resolved Compose model; Nginx was not changed"
