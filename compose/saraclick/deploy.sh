#!/usr/bin/env bash
set -euo pipefail
umask 077

app_dir=${1:?missing production directory}
web_image=${2:?missing pinned web image}
backend_image=${3:?missing pinned backend image}
asset_dir=$(cd -- "$(dirname -- "$0")" && pwd)
[[ "$app_dir" == /* && "$app_dir" != *..* ]] || exit 2
for image in "$web_image" "$backend_image"; do
  [[ "$image" =~ ^[a-z0-9.-]+(:[0-9]+)?/leaperone/saraclick@sha256:[0-9a-f]{64}$ ]] || exit 2
done
cd "$app_dir"
# Initial activation belongs to the cutover operator, never a routine release.
test -f .cutover-complete || { echo 'ERROR: production cutover is incomplete' >&2; exit 1; }
for file in web.env backend.env deployment.env; do
  test -s "$file" || { echo "ERROR: required $file is missing" >&2; exit 1; }
done
exec 9>.deploy.lock
flock -x 9

export SARACLICK_WEB_IMAGE="$web_image" SARACLICK_BACKEND_IMAGE="$backend_image"
compose=(docker compose --env-file deployment.env -f "$asset_dir/docker-compose.yml" --project-directory "$app_dir")
diagnostic="$app_dir/.deploy-diagnostic"
install -m 600 /dev/null "$diagnostic"
config=$(mktemp)
trap 'rm -f "$config"' EXIT
"${compose[@]}" config --format json > "$config" 2>"$diagnostic"
python3 - "$config" deployment.env <<'PY'
import json
import sys
from urllib.parse import unquote, urlsplit

try:
    deployment = dict(line.strip().split('=', 1) for line in open(sys.argv[2])
                      if line.strip() and not line.lstrip().startswith('#'))
    expected_host = deployment['SARACLICK_DATABASE_HOST']
    expected_port = int(deployment['SARACLICK_DATABASE_PORT'])
    services = json.load(open(sys.argv[1]))['services']
    for name in ('saraclick', 'saraclick-backend'):
        url = urlsplit(services[name]['environment']['SARACLICK_DATABASE_URL'])
        if not (url.scheme in ('postgres', 'postgresql')
                and url.hostname == expected_host and url.port == expected_port
                and unquote(url.username or '') == 'saraclick_app'
                and url.path == '/saraclick_db' and url.password
                and not url.fragment):
            raise ValueError()
except (KeyError, ValueError, TypeError):
    sys.exit('ERROR: both runtime environments must use the production SaraClick database role and endpoint')
PY
rm -f "$config"

if ! "${compose[@]}" pull --quiet >"$diagnostic" 2>&1; then
  echo 'ERROR: image pull failed; private diagnostics retained on host' >&2
  exit 1
fi
# Pins change only after health checks succeed. A failed release restores the
# previous image pair against the same validated runtime environment.
# Prisma method names contain literal dollar signs inside the Deno program.
# shellcheck disable=SC2016
if ! { "${compose[@]}" up -d --wait --wait-timeout 180 >"$diagnostic" 2>&1 &&
  "${compose[@]}" exec -T saraclick-backend deno eval \
    'import { PrismaClient } from "./prisma/client_saraclick_deno/client.ts"; const db = new PrismaClient(); try { await db.$queryRawUnsafe("SELECT 1"); } finally { await db.$disconnect(); }' \
    >>"$diagnostic" 2>&1; }; then
  if test -s release.env; then
    unset SARACLICK_WEB_IMAGE SARACLICK_BACKEND_IMAGE
    if docker compose --env-file deployment.env --env-file release.env \
      -f "$asset_dir/docker-compose.yml" --project-directory "$app_dir" \
      up -d --wait --wait-timeout 180 >>"$diagnostic" 2>&1; then
      echo 'Previous image pair restored.' >&2
    else
      echo 'ERROR: restoring the previous image pair failed; inspect private diagnostics' >&2
    fi
  fi
  echo 'ERROR: release health checks failed; private diagnostics retained on host' >&2
  exit 1
fi
printf 'SARACLICK_WEB_IMAGE=%s\nSARACLICK_BACKEND_IMAGE=%s\n' "$web_image" "$backend_image" > release.env.next
mv release.env.next release.env
install -m 600 "$asset_dir/docker-compose.yml" docker-compose.yml
rm -f "$diagnostic"
echo 'SaraClick production image pair is healthy.'
