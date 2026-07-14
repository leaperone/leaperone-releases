#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/.github/workflows/deploy-leaperone-frontend.yml"
PAIR="$ROOT/.github/workflows/deploy-leaperone-frontends.yml"
WWW="$ROOT/.github/workflows/deploy-leaperone-www.yml"
DASHBOARD="$ROOT/.github/workflows/deploy-leaperone-dashboard.yml"
API="$ROOT/.github/workflows/deploy-leaperone.yml"
DEPLOY="$ROOT/.github/workflows/deploy-de.yml"
CUTOVER="$ROOT/ops/leaperone-frontend/cutover/cutover-nginx.sh"
API_COMPOSE="$ROOT/compose/leaperone/docker-compose.yml"
DEPLOY_SCRIPT="$ROOT/scripts/deploy.sh"
WWW_TOMBSTONE="$ROOT/compose/leaperone-www/scripts/10-install-nginx-conf.sh"

require_text() {
  grep -Fq -- "$2" "$1" || {
    echo "ERROR: missing workflow contract in $1: $2" >&2
    exit 1
  }
}

require_text "$FRONTEND" 'SENTRY_AUTH_TOKEN_FILE: ${{ steps.sentry-secret.outputs.path }}'
require_text "$FRONTEND" 'NEXT_SERVER_ACTIONS_ENCRYPTION_KEY_FILE: ${{ steps.sentry-secret.outputs.actions_path }}'
require_text "$FRONTEND" "grep -q 'id=next_server_actions_encryption_key'"
require_text "$FRONTEND" 'value: ${{ jobs.build.outputs.source_sha }}'
require_text "$FRONTEND" 'value: ${{ jobs.build.outputs.image_ref }}'
require_text "$FRONTEND" 'value: ${{ jobs.build.outputs.image_digest }}'
require_text "$FRONTEND" 'RESOLVED_REF="refs/heads/main"'
require_text "$FRONTEND" 'RESOLVED_REF="$REQUESTED_REF"'
require_text "$FRONTEND" 'RESOLVED_REF="refs/tags/$REQUESTED_REF"'

require_text "$PAIR" 'types: [deploy-leaperone-frontends]'
require_text "$PAIR" 'group: leaperone-frontends-production'
require_text "$PAIR" 'needs: [validate, dashboard]'
require_text "$PAIR" 'needs: [validate, dashboard, www]'
require_text "$PAIR" 'requested_source_sha: ${{ needs.validate.outputs.source_sha }}'
require_text "$PAIR" 'WWW_IMAGE_DIGEST: ${{ needs.www.outputs.image_digest }}'
require_text "$PAIR" 'DASHBOARD_IMAGE_DIGEST: ${{ needs.dashboard.outputs.image_digest }}'
require_text "$PAIR" 'bash "$CUTOVER_DIR/cutover-nginx.sh"'
require_text "$WWW" 'group: leaperone-frontends-production'
require_text "$DASHBOARD" 'group: leaperone-frontends-production'

require_text "$API" 'name: Deploy LEAPERone API'
require_text "$API" 'COMPONENTS="api"'
require_text "$API" 'components=api'
require_text "$API" 'test -f apps/api/Dockerfile'
require_text "$API" 'build leaperone-api'
require_text "$API" 'docker tag "${REGISTRY_IMAGE}:api-latest" "${REGISTRY_IMAGE}:api-${SOURCE_SHA}"'
require_text "$API" 'LEAPERONE_DE_DATABASE_URL is required for DE migrations'
require_text "$API" '- name: Run Database Migrations'
require_text "$API" 'pnpm --filter @leaperone/db db:migrate'
require_text "$API_COMPOSE" 'services:'
require_text "$API_COMPOSE" '  api:'
require_text "$API_COMPOSE" '${API_IMAGE_TAG:?API_IMAGE_TAG must be an immutable API source-SHA tag}'
require_text "$API_COMPOSE" '      - .env.api'
require_text "$DEPLOY_SCRIPT" 'LEAPERone is an API-only compose project'
require_text "$DEPLOY_SCRIPT" 'LEAPERone API-only deploy: post-deploy scripts are disabled'
require_text "$DEPLOY" 'export API_IMAGE_TAG="api-${IMAGE_SOURCE_SHA}"'
require_text "$DEPLOY" 'retire_legacy_payload'
require_text "$DEPLOY" 'retired-release-payloads'
require_text "$DEPLOY" 'legacy-install-nginx-conf.sh'
require_text "$DEPLOY" 'legacy-leaperone-local.conf'
require_text "$DEPLOY" 'sha256sum "$backup"'

require_text "$DEPLOY" "WWW_IMAGE_DIGEST=\"\$IMAGE_DIGEST\""
require_text "$DEPLOY" "DASHBOARD_IMAGE_DIGEST=\"\$IMAGE_DIGEST\""
require_text "$DEPLOY" "{{range .RepoDigests}}{{println .}}{{end}}"
require_text "$DEPLOY" '"migration":"none"'
require_text "$CUTOVER" 'verify_repo_digest leaperone-www-production'
require_text "$CUTOVER" 'verify_repo_digest leaperone-dashboard-production'
require_text "$CUTOVER" 'http://127.0.0.1:9821/api/ready'
require_text "$CUTOVER" 'frontend-cutovers.jsonl'
require_text "$CUTOVER" '"migration":"none"'
require_text "$WWW_TOMBSTONE" 'routing is owned by the paired cutover workflow'

if grep -Eq 'nginx -s reload|TARGET_CONFIG=|leaperone-local\.conf' "$WWW_TOMBSTONE"; then
  echo "ERROR: a component tombstone still contains nginx mutation logic" >&2
  exit 1
fi

if rg -n 'leaperone-web|web-latest|WEB_IMAGE_TAG|\.env\.web|127\.0\.0\.1:9800' \
  "$API" "$API_COMPOSE" "$DEPLOY" "$DEPLOY_SCRIPT"; then
  echo "ERROR: the API-only release path still references the retired legacy Web" >&2
  exit 1
fi

if find "$ROOT/compose/leaperone" -type f \
  \( -path '*/nginx/*' -o -path '*/scripts/*' \) -print | grep -q .; then
  echo "ERROR: the API-only compose project still ships legacy routing payloads" >&2
  exit 1
fi

leaperone_post_deploy_block="$(awk '
  index($0, "if [ \"$PROJECT\" = \"leaperone\" ]; then") { capture = 1 }
  capture { print }
  index($0, "elif [ -d \"$APP_DIR/scripts\" ]; then") { exit }
' "$DEPLOY_SCRIPT")"
if grep -Eq 'for script|"\$script"|10-install-nginx-conf' <<< "$leaperone_post_deploy_block"; then
  echo "ERROR: LEAPERone API deploy can still execute a stale post-deploy installer" >&2
  exit 1
fi

if rg -n 'db:migrate|Run Database Migrations|LEAPERONE_DE_DATABASE_URL' \
  "$FRONTEND" "$PAIR" "$WWW" "$DASHBOARD"; then
  echo "ERROR: split frontend workflows contain migration logic" >&2
  exit 1
fi

frontend_build_block="$(sed -n '/- name: Build selected frontend image/,/- name: Remove frontend BuildKit secrets/p' "$FRONTEND")"
if grep -Eq 'SENTRY_AUTH_TOKEN:|NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:' <<< "$frontend_build_block"; then
  echo "ERROR: a Compose build step receives a real BuildKit secret value as an environment variable" >&2
  exit 1
fi

echo "API-only, paired frontend, secret, digest, cutover, and migration-owner contracts passed"
