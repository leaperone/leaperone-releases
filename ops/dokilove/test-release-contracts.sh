#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/deploy-dokilove.yml"
DEPLOY_DE="$ROOT/.github/workflows/deploy-de.yml"
NIMEI_COMPOSE="$ROOT/compose/nimei/docker-compose.yml"

require_text() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "ERROR: missing '$needle' in ${file#"$ROOT/"}" >&2
    exit 1
  }
}

require_text 'build_nimei:' "$WORKFLOW"
require_text 'components=nimei or components=all' "$WORKFLOW"
require_text 'source_sha: ${{ steps.pin.outputs.source_sha }}' "$WORKFLOW"
require_text 'client_payload.source_sha does not match the resolved ref commit' "$WORKFLOW"
require_text 'pnpm --filter @dokilove/db db:migrate' "$WORKFLOW"
require_text 'DOKILOVE_POSTHOG_PROJECT_KEY' "$WORKFLOW"
require_text 'NEXT_PUBLIC_POSTHOG_HOST: https://t.doki.love' "$WORKFLOW"
require_text 'SENTRY_PROJECT: dokilove-web' "$WORKFLOW"
require_text 'SENTRY_RELEASE: nimei-web@' "$WORKFLOW"
require_text 'Back up DE database before migration 0027' "$WORKFLOW"
require_text 'https://doki.love/api/auth/sign-up/email' "$WORKFLOW"
require_text 'nimei-cutover-complete.json' "$WORKFLOW"
require_text 'safety_attestation: doki-consumer-lockout-v1' "$WORKFLOW"
require_text 'push_with_digest()' "$WORKFLOW"
require_text 'dokilove_image_digest:' "$WORKFLOW"
require_text 'nimei_image_digest:' "$WORKFLOW"
require_text 'migrated-unsealed' "$WORKFLOW"
require_text 'nimei-cutover-pending.env' "$WORKFLOW"
require_text 'Sync and validate NIMEI origin prerequisites' "$WORKFLOW"
require_text "if: needs.resolve-context.outputs.build_nimei == 'true'" "$WORKFLOW"
require_text 'project: nimei' "$WORKFLOW"
require_text 'dokilove|nimei)' "$DEPLOY_DE"
require_text 'export DEPLOY_IMAGE_REF="$EXPECTED_REPO_DIGEST"' "$DEPLOY_DE"
require_text '127.0.0.1:${WEB_PORT:-9811}:3000' "$NIMEI_COMPOSE"
require_text 'SENTRY_RELEASE: ${SENTRY_RELEASE:-}' "$NIMEI_COMPOSE"
require_text 'READY_PATH=/api/ready' "$ROOT/compose/nimei/deploy-bluegreen.sh"
require_text 'listen 80;' "$ROOT/compose/nimei/nginx/nimei-local.conf"
require_text 'return 301 https://nimei.app$request_uri;' "$ROOT/compose/nimei/nginx/nimei-local.conf"
require_text 'NIMEI AUTH_SECRET and BETTER_AUTH_SECRET must be identical' "$ROOT/compose/nimei/preflight.sh"
require_text 'NIMEI auth secret must be independent from DokiLove' "$ROOT/compose/nimei/preflight.sh"
require_text 'NIMEI ENCRYPTION_KEY must match DokiLove' "$ROOT/compose/nimei/preflight.sh"
require_text 'NIMEI SENTRY_DSN must match DokiLove' "$ROOT/compose/nimei/preflight.sh"
require_text 'TRUSTED_PROXY must be 1' "$ROOT/compose/nimei/preflight.sh"
require_text 'NIMEI deploy requires digest-pinned DEPLOY_IMAGE_REF' "$ROOT/compose/nimei/deploy-bluegreen.sh"

if grep -qE 'NIMEI_NEXT_PUBLIC_(POSTHOG|SENTRY)' "$WORKFLOW"; then
  echo "ERROR: NIMEI must use the shared NEXT_PUBLIC_POSTHOG/SENTRY build contract" >&2
  exit 1
fi

if perl -0777 -ne '
  while (/^[ ]+run:[ ]*\|\n((?:[ ]{10,}.*\n)*)/mg) {
    if ($1 =~ /github\.event\.client_payload/) { exit 1 }
  }
' "$WORKFLOW"; then
  :
else
  echo "ERROR: repository_dispatch payload expression appears inside a run script" >&2
  exit 1
fi

checkout_count="$(grep -cE 'uses: actions/checkout@' "$WORKFLOW")"
persist_false_count="$(grep -cF 'persist-credentials: false' "$WORKFLOW")"
[ "$checkout_count" = "$persist_false_count" ] || {
  echo "ERROR: every deploy-dokilove checkout must disable persisted credentials" >&2
  exit 1
}

sample_push_output='web-deadbeef: digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef size: 1987'
parsed_digest="$(sed -nE 's/^.*digest: (sha256:[0-9a-f]{64}).*$/\1/p' <<< "$sample_push_output")"
[ "$parsed_digest" = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' ] || {
  echo "ERROR: registry push digest parser contract failed" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$NIMEI_COMPOSE" "$tmp/docker-compose.yml"
: > "$tmp/.env"
(
  cd "$tmp"
  COLOR=blue WEB_PORT=9811 IMAGE_TAG=web-0123456789abcdef0123456789abcdef01234567 \
    docker compose config --quiet
  COLOR=green WEB_PORT=9812 IMAGE_TAG=web-0123456789abcdef0123456789abcdef01234567 \
    docker compose config --quiet
  DEPLOY_IMAGE_REF=registry.cn-hongkong.aliyuncs.com/leaperone/nimei@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    IMAGE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
    IMAGE_DIGEST=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    docker compose config | grep -Fq \
      'image: registry.cn-hongkong.aliyuncs.com/leaperone/nimei@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
)

services="$(
  cd "$tmp"
  docker compose config --services
)"
[ "$services" = "web" ] || {
  echo "ERROR: NIMEI compose must contain only the web service" >&2
  exit 1
}

echo "DokiLove/NIMEI release contracts OK"
