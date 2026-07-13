#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FRONTEND="$ROOT/.github/workflows/deploy-leaperone-frontend.yml"
LEGACY="$ROOT/.github/workflows/deploy-leaperone.yml"
DEPLOY="$ROOT/.github/workflows/deploy-de.yml"

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
require_text "$FRONTEND" 'image_digest: ${{ steps.publish.outputs.image_digest }}'
require_text "$FRONTEND" 'image_digest: ${{ needs.build.outputs.image_digest }}'
require_text "$FRONTEND" 'RESOLVED_REF="refs/heads/main"'
require_text "$FRONTEND" 'RESOLVED_REF="refs/tags/$REQUESTED_REF"'
require_text "$DEPLOY" "WWW_IMAGE_DIGEST=\"\$IMAGE_DIGEST\""
require_text "$DEPLOY" "DASHBOARD_IMAGE_DIGEST=\"\$IMAGE_DIGEST\""
require_text "$DEPLOY" "{{range .RepoDigests}}{{println .}}{{end}}"
require_text "$DEPLOY" "/var/lib/leaperone/deployments"
require_text "$DEPLOY" '"migration":"none"'

if rg -n 'db:migrate|Run Database Migrations|LEAPERONE_DE_DATABASE_URL' \
  "$FRONTEND" "$ROOT/.github/workflows/deploy-leaperone-www.yml" \
  "$ROOT/.github/workflows/deploy-leaperone-dashboard.yml"; then
  echo "ERROR: split frontend workflows contain migration logic" >&2
  exit 1
fi

frontend_build_block="$(sed -n '/- name: Build selected frontend image/,/- name: Remove frontend BuildKit secrets/p' "$FRONTEND")"
legacy_build_block="$(sed -n '/- name: Build Docker images/,/- name: Remove Web BuildKit secrets/p' "$LEGACY")"
if grep -Eq 'SENTRY_AUTH_TOKEN:|NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:' <<< "$frontend_build_block$legacy_build_block"; then
  echo "ERROR: a Compose build step receives a real BuildKit secret value as an environment variable" >&2
  exit 1
fi

echo "Workflow secret, digest, evidence, and no-migration contracts passed"
