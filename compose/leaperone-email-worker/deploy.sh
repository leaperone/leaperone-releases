#!/usr/bin/env bash
set -euo pipefail

SOURCE_SHA="${1:?Usage: deploy.sh <source-sha> <image-digest> <release-tag> <releases-sha>}"
IMAGE_DIGEST="${2:?Usage: deploy.sh <source-sha> <image-digest> <release-tag> <releases-sha>}"
RELEASE_TAG="${3:?Usage: deploy.sh <source-sha> <image-digest> <release-tag> <releases-sha>}"
RELEASES_SHA="${4:?Usage: deploy.sh <source-sha> <image-digest> <release-tag> <releases-sha>}"

APP_DIR=/home/leaperone/services/leaperone-email-worker
ENV_FILE="$APP_DIR/.env"
PREFLIGHT="$APP_DIR/preflight.sh"
CONTAINER_NAME=leaperone-email-worker-production
LOCK_FILE="$APP_DIR/.deploy.lock"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

read_env_value() {
  local file="$1" key="$2"
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      sub("^[^=]*=", "")
      sub("\\r$", "")
      print
      exit
    }
  ' "$file"
}

upsert_env_value() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v wanted="$key" -v replacement="$value" '
    BEGIN { written=0 }
    index($0, wanted "=") == 1 {
      if (!written) print wanted "=" replacement
      written=1
      next
    }
    { print }
    END { if (!written) print wanted "=" replacement }
  ' "$file" > "$temporary"
  chmod --reference="$file" "$temporary"
  mv -f "$temporary" "$file"
}

verify_deployment() {
  local source_sha="$1" image_digest="$2" release_tag="$3" releases_sha="$4"
  local container_image_id expected_repo_digest
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME")" = healthy ] || return 1
  container_image_id="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME")"
  expected_repo_digest="registry.cn-hongkong.aliyuncs.com/leaperone/leaperone@${image_digest}"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$container_image_id" \
    | grep -Fxq "$expected_repo_digest" || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.component"}}' "$CONTAINER_NAME")" = email-worker ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.source-sha"}}' "$CONTAINER_NAME")" = "$source_sha" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.release-tag"}}' "$CONTAINER_NAME")" = "$release_tag" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.releases-sha"}}' "$CONTAINER_NAME")" = "$releases_sha" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.image-digest"}}' "$CONTAINER_NAME")" = "$image_digest" ] || return 1
}

deploy_current_env() {
  "$PREFLIGHT" || return 1
  docker compose pull || return 1
  docker compose up -d --remove-orphans --wait --wait-timeout 180 || return 1
}

restore_previous_env() {
  # Prefer the previously running local RepoDigest so a transient registry or
  # credential failure cannot by itself prevent rollback. Pull only if the
  # local restore path is unavailable.
  if "$PREFLIGHT" &&
     docker compose up -d --remove-orphans --wait --wait-timeout 180; then
    return 0
  fi
  deploy_current_env
}

[ "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" = "$APP_DIR" ] || \
  fail "deploy.sh must run from $APP_DIR"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source SHA"
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid image digest"
[[ "$RELEASE_TAG" =~ ^email-worker-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
  fail "invalid email-worker release tag"
[[ "$RELEASES_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid releases repository SHA"
[ -s "$ENV_FILE" ] || fail "$ENV_FILE is missing or empty"
[ -s "$APP_DIR/.env.worker" ] || fail "$APP_DIR/.env.worker is missing or empty"
[ -x "$PREFLIGHT" ] || fail "$PREFLIGHT is missing or not executable"

exec 9>"$LOCK_FILE"
flock -x 9
cd "$APP_DIR"

backup="$(mktemp "$APP_DIR/.env.rollback.XXXXXX")"
cp -p "$ENV_FILE" "$backup"
trap 'rm -f "$backup"' EXIT

previous_tag="$(read_env_value "$ENV_FILE" EMAIL_WORKER_IMAGE_TAG)"
previous_digest="$(read_env_value "$ENV_FILE" EMAIL_WORKER_IMAGE_DIGEST)"
previous_source_sha="$(read_env_value "$ENV_FILE" EMAIL_WORKER_SOURCE_SHA)"
previous_release_tag="$(read_env_value "$ENV_FILE" EMAIL_WORKER_RELEASE_TAG)"
previous_releases_sha="$(read_env_value "$ENV_FILE" RELEASES_SHA)"
initial_container_id="$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null || true)"

rollback_available=false
if [[ "$previous_tag" =~ ^email-worker-[0-9a-f]{40}$ ]] &&
   [[ "$previous_digest" =~ ^sha256:[0-9a-f]{64}$ ]] &&
   [[ "$previous_source_sha" =~ ^[0-9a-f]{40}$ ]] &&
   [ "$previous_tag" = "email-worker-$previous_source_sha" ] &&
   [[ "$previous_release_tag" =~ ^email-worker-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] &&
   [[ "$previous_releases_sha" =~ ^[0-9a-f]{40}$ ]]; then
  rollback_available=true
fi

upsert_env_value "$ENV_FILE" EMAIL_WORKER_IMAGE_TAG "email-worker-$SOURCE_SHA"
upsert_env_value "$ENV_FILE" EMAIL_WORKER_IMAGE_DIGEST "$IMAGE_DIGEST"
upsert_env_value "$ENV_FILE" EMAIL_WORKER_SOURCE_SHA "$SOURCE_SHA"
upsert_env_value "$ENV_FILE" EMAIL_WORKER_RELEASE_TAG "$RELEASE_TAG"
upsert_env_value "$ENV_FILE" RELEASES_SHA "$RELEASES_SHA"

if deploy_current_env && verify_deployment "$SOURCE_SHA" "$IMAGE_DIGEST" "$RELEASE_TAG" "$RELEASES_SHA"; then
  printf 'Email Worker deploy complete: %s (%s)\n' "$RELEASE_TAG" "$SOURCE_SHA"
  docker compose ps
  exit 0
fi

echo "ERROR: candidate Email Worker failed; restoring previous deployment" >&2
cp -p "$backup" "$ENV_FILE"

if [ "$rollback_available" = true ]; then
  if restore_previous_env && verify_deployment \
    "$previous_source_sha" "$previous_digest" "$previous_release_tag" "$previous_releases_sha"; then
    echo "Automatic rollback succeeded: $previous_release_tag ($previous_source_sha)" >&2
    exit 1
  fi
  echo "CRITICAL: candidate failed and automatic rollback also failed" >&2
  exit 2
fi

if [ -z "$initial_container_id" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi
echo "ERROR: no valid previous image metadata was available for automatic rollback" >&2
exit 1
