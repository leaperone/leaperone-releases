#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/.github/workflows/deploy-leaperone-frontend.yml"
PAIR="$ROOT/.github/workflows/deploy-leaperone-frontends.yml"
WWW="$ROOT/.github/workflows/deploy-leaperone-www.yml"
DASHBOARD="$ROOT/.github/workflows/deploy-leaperone-dashboard.yml"
LEGACY="$ROOT/.github/workflows/deploy-leaperone.yml"
DEPLOY="$ROOT/.github/workflows/deploy-de.yml"
CUTOVER="$ROOT/ops/leaperone-frontend/cutover/cutover-nginx.sh"
WWW_TOMBSTONE="$ROOT/compose/leaperone-www/scripts/10-install-nginx-conf.sh"
LEGACY_TOMBSTONE="$ROOT/compose/leaperone/scripts/10-install-nginx-conf.sh"

require_text() {
  grep -Fq "$2" "$1" || {
    echo "ERROR: missing workflow contract in $1: $2" >&2
    exit 1
  }
}

require_text "$FRONTEND" 'SENTRY_AUTH_TOKEN_FILE: ${{ steps.sentry-secret.outputs.path }}'
require_text "$LEGACY" "SENTRY_AUTH_TOKEN_FILE: \${{ steps.sentry-secret.outputs.path || '/dev/null' }}"
require_text "$FRONTEND" 'NEXT_SERVER_ACTIONS_ENCRYPTION_KEY_FILE: ${{ steps.sentry-secret.outputs.actions_path }}'
require_text "$LEGACY" "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY_FILE: \${{ steps.sentry-secret.outputs.actions_path || '/dev/null' }}"
require_text "$FRONTEND" "grep -q 'id=next_server_actions_encryption_key'"
require_text "$LEGACY" "grep -q 'id=next_server_actions_encryption_key'"
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
require_text "$LEGACY_TOMBSTONE" 'Nginx routing is managed separately'

if grep -Eq 'nginx -s reload|TARGET_CONFIG=|leaperone-local\.conf' "$WWW_TOMBSTONE" "$LEGACY_TOMBSTONE"; then
  echo "ERROR: a component tombstone still contains nginx mutation logic" >&2
  exit 1
fi

if rg -n 'db:migrate|Run Database Migrations|LEAPERONE_DE_DATABASE_URL' \
  "$FRONTEND" "$PAIR" "$WWW" "$DASHBOARD"; then
  echo "ERROR: split frontend workflows contain migration logic" >&2
  exit 1
fi

frontend_build_block="$(sed -n '/- name: Build selected frontend image/,/- name: Remove frontend BuildKit secrets/p' "$FRONTEND")"
legacy_build_block="$(sed -n '/- name: Build Docker images/,/- name: Remove Web BuildKit secrets/p' "$LEGACY")"
if grep -Eq 'SENTRY_AUTH_TOKEN:|NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:' <<< "$frontend_build_block$legacy_build_block"; then
  echo "ERROR: a Compose build step receives a real BuildKit secret value as an environment variable" >&2
  exit 1
fi

echo "Paired deploy, secret, digest, cutover, and no-migration contracts passed"
