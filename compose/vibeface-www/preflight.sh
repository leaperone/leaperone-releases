#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
: "${DEPLOY_ENV:=production}"
: "${REGISTRY_HOST:=de.leaper.one:5443}"
[[ "$DEPLOY_ENV" = production ]] || { echo 'ERROR: DEPLOY_ENV must be production' >&2; exit 1; }
[[ "$REGISTRY_HOST" = de.leaper.one:5443 ]] || { echo 'ERROR: unexpected registry host' >&2; exit 1; }
[[ "${VIBEFACE_IMAGE_TAG:-}" =~ ^www-[0-9a-f]{40}$ ]] || { echo 'ERROR: invalid VIBEFACE_IMAGE_TAG' >&2; exit 1; }
[[ "${VIBEFACE_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'ERROR: invalid VIBEFACE_IMAGE_DIGEST' >&2; exit 1; }
[[ "${VIBEFACE_PORT:-9833}" = 9833 ]] || { echo 'ERROR: VIBEFACE_PORT must remain 9833' >&2; exit 1; }
docker network inspect bridge >/dev/null
docker compose config --quiet
echo "vibeface-www preflight passed: ${VIBEFACE_IMAGE_TAG} -> 127.0.0.1:9833"
