#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -eq 3 ]] || fail "usage: deploy-core.sh <www-image@digest> <dashboard-image@digest> <api-image@digest>"
next_www="$1"; next_dashboard="$2"; next_api="$3"
[[ "${DEPLOY_ENV:-production}" == production ]] || fail "DEPLOY_ENV must be production"
[[ -f .env ]] || fail ".env is required (host-managed ports only)"
set -a
# shellcheck disable=SC1091
. ./.env
set +a
[[ -x ./preflight.sh ]] || fail "preflight.sh must be executable"
if [[ -s .images.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.images.env
  set +a
  if [[ -s .current-compose.yml ]]; then
    cp .current-compose.yml .previous-compose.yml
  else
    docker compose config --quiet
    docker compose config > .previous-compose.yml.tmp
    mv .previous-compose.yml.tmp .previous-compose.yml
  fi
  cp .images.env .previous-images.env
fi
export WWW_IMAGE_REF="$next_www" DASHBOARD_IMAGE_REF="$next_dashboard" API_IMAGE_REF="$next_api"
./preflight.sh
resolved_config="$(docker compose config)"
grep -Eq 'ENABLE_IMAGE_WORKER: "?false"?' <<<"$resolved_config" || fail "image worker is not disabled"
grep -Eq 'ENABLE_VIDEO_WORKER: "?false"?' <<<"$resolved_config" || fail "video worker is not disabled"
grep -Eq 'RUN_MIGRATIONS: "?false"?' <<<"$resolved_config" || fail "migrations are not disabled"
docker compose pull
restore_on_failure() {
  result=$?
  if [[ "$result" != 0 && -s .previous-compose.yml ]]; then
    echo "ERROR: deployment acceptance failed; restoring the previous containers" >&2
    ./rollback.sh || echo "ERROR: automatic rollback failed; inspect the saved previous configuration" >&2
  fi
  exit "$result"
}
trap restore_on_failure EXIT
docker compose up -d --wait --wait-timeout 180
api_release="${API_IMAGE_REF#*:api-}"; api_release="${api_release%@*}"
./verify-core.sh "$api_release"
printf 'WWW_IMAGE_REF=%s\nDASHBOARD_IMAGE_REF=%s\nAPI_IMAGE_REF=%s\n' "$WWW_IMAGE_REF" "$DASHBOARD_IMAGE_REF" "$API_IMAGE_REF" > .images.env.tmp
mv .images.env.tmp .images.env
docker compose config > .current-compose.yml.tmp
mv .current-compose.yml.tmp .current-compose.yml
trap - EXIT
echo "UnderSky core deployment is healthy; Nginx was not changed"
