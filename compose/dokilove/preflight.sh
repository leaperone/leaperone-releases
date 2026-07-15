#!/bin/bash
# Once migration 0027 has split consumer identity into NIMEI, DokiLove may only
# run immutable source SHAs that the release workflow attested as consumer-write
# disabled. This deliberately blocks legacy `latest` rollback after cutover.
set -euo pipefail

CUTOVER_MARKER=/var/lib/dokilove/nimei-cutover-complete.json
SAFE_IMAGE_DIR=/var/lib/dokilove/consumer-lockout-images

if [ ! -e "$CUTOVER_MARKER" ]; then
  exit 0
fi

if [[ ! "${IMAGE_TAG:-}" =~ ^web-[0-9a-f]{40}$ ]]; then
  echo "ERROR: post-0027 DokiLove deploy requires immutable IMAGE_TAG=web-<40-char-sha>" >&2
  exit 1
fi
source_sha="${IMAGE_TAG#web-}"

if [ ! -f "$SAFE_IMAGE_DIR/$source_sha" ]; then
  echo "ERROR: DokiLove image $source_sha has no consumer-lockout attestation" >&2
  exit 1
fi

: "${DEPLOY_IMAGE_REF:?post-0027 DokiLove deploy requires digest-pinned DEPLOY_IMAGE_REF}"
[[ "$DEPLOY_IMAGE_REF" =~ ^registry\.cn-hongkong\.aliyuncs\.com/leaperone/dokilove@sha256:[0-9a-f]{64}$ ]] || {
  echo "ERROR: invalid post-0027 DokiLove RepoDigest" >&2
  exit 1
}
attested_repo_digest="$(tr -d '\r\n' < "$SAFE_IMAGE_DIR/$source_sha")"
[ "$attested_repo_digest" = "$DEPLOY_IMAGE_REF" ] || {
  echo "ERROR: DokiLove RepoDigest does not match the consumer-lockout attestation" >&2
  exit 1
}
