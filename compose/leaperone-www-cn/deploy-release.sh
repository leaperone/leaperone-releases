#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
./preflight.sh
# .env is root-owned mode 0600 and its keys were allow-listed by preflight.
# shellcheck disable=SC1091
. ./.env
export DEPLOY_ENV REGISTRY_HOST WWW_CN_PORT WWW_CN_CONTAINER_NAME DEPLOY_STATE_ROOT

CONTAINER="$WWW_CN_CONTAINER_NAME"
STATE_DIR="${DEPLOY_STATE_ROOT}/leaperone-www-cn"
CURRENT_FILE="$STATE_DIR/current.env"
HISTORY_DIR="$STATE_DIR/history"
RECORD_FILE="${DEPLOY_STATE_ROOT}/frontend-deployments.jsonl"
EXPECTED_REPO_DIGEST="registry.cn-hongkong.aliyuncs.com/leaperone/leaperone@${WWW_CN_IMAGE_DIGEST}"
HTML_FILE="$(mktemp)"
trap 'rm -f "$HTML_FILE"' EXIT

verify_release() {
  local image_id
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" = healthy ] || return 1
  image_id="$(docker inspect --format '{{.Image}}' "$CONTAINER")"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" \
    | grep -Fxq "$EXPECTED_REPO_DIGEST" || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.source-sha"}}' "$CONTAINER")" = "$WWW_CN_SOURCE_SHA" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$CONTAINER")" = "$WWW_CN_SOURCE_SHA" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.image-digest"}}' "$CONTAINER")" = "$WWW_CN_IMAGE_DIGEST" ] || return 1
  [ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.site-region"}}' "$CONTAINER")" = cn ] || return 1
  curl -fsS --max-time 10 "http://127.0.0.1:${WWW_CN_PORT}/api/health" >/dev/null || return 1
  curl -fsS --max-time 10 "http://127.0.0.1:${WWW_CN_PORT}/zh" > "$HTML_FILE" || return 1
  grep -Fq '粤ICP备2024184990号-4' "$HTML_FILE" || return 1
  ! grep -Eiq 'OpenAI|Claude|GPT' "$HTML_FILE"
}

activate_release() {
  EXPECTED_REPO_DIGEST="registry.cn-hongkong.aliyuncs.com/leaperone/leaperone@${WWW_CN_IMAGE_DIGEST}"
  docker compose up -d --remove-orphans --wait --wait-timeout 180 || return 1
  verify_release
}

start_release() {
  docker compose pull || return 1
  activate_release
}

quarantine_bootstrap_container() {
  [ ! -s "$CURRENT_FILE" ] || return 0
  docker container inspect "$CONTAINER" >/dev/null 2>&1 || return 0
  BOOTSTRAP_CONTAINER="${CONTAINER}-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  echo "==> Preserving pre-workflow container as ${BOOTSTRAP_CONTAINER}..."
  docker rename "$CONTAINER" "$BOOTSTRAP_CONTAINER" || return 1
  if ! docker stop --time 30 "$BOOTSTRAP_CONTAINER" >/dev/null; then
    docker rename "$BOOTSTRAP_CONTAINER" "$CONTAINER" || true
    BOOTSTRAP_CONTAINER=
    return 1
  fi
}

restore_bootstrap_container() {
  [ -n "${BOOTSTRAP_CONTAINER:-}" ] || return 1
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rename "$BOOTSTRAP_CONTAINER" "$CONTAINER" || return 1
  BOOTSTRAP_CONTAINER=
  docker start "$CONTAINER" >/dev/null || return 1
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${WWW_CN_PORT}/api/health" >/dev/null; then
      return 0
    fi
    [ "$attempt" -lt 30 ] || return 1
    sleep 2
  done
}

restore_previous() {
  local previous_file="$1"
  [ -s "$previous_file" ] || return 1
  # current.env is generated below from validated hashes and fixed registry refs.
  # shellcheck disable=SC1090
  . "$previous_file"
  export WWW_CN_SOURCE_SHA WWW_CN_IMAGE_TAG WWW_CN_IMAGE_DIGEST IMAGE_REF RELEASES_SHA
  echo "==> Restoring previous CN release ${WWW_CN_SOURCE_SHA}..."
  start_release
}

persist_release() {
  local deployed_at
  local stamp
  local tmp
  deployed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "$STATE_DIR" "$HISTORY_DIR"
  tmp="$(mktemp "$STATE_DIR/current.env.XXXXXX")"
  {
    printf 'WWW_CN_SOURCE_SHA=%s\n' "$WWW_CN_SOURCE_SHA"
    printf 'WWW_CN_IMAGE_TAG=%s\n' "$WWW_CN_IMAGE_TAG"
    printf 'WWW_CN_IMAGE_DIGEST=%s\n' "$WWW_CN_IMAGE_DIGEST"
    printf 'IMAGE_REF=%s\n' "$IMAGE_REF"
    printf 'RELEASES_SHA=%s\n' "$RELEASES_SHA"
    printf 'DEPLOYED_AT=%s\n' "$deployed_at"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$CURRENT_FILE"
  install -m 0600 "$CURRENT_FILE" "$HISTORY_DIR/${stamp}-${WWW_CN_SOURCE_SHA}.env"

  install -d -m 0700 "$(dirname "$RECORD_FILE")"
  if [ ! -f "$RECORD_FILE" ]; then
    install -m 0600 /dev/null "$RECORD_FILE"
  fi
  chmod 0600 "$RECORD_FILE"
  printf '{"component":"www-cn","source_sha":"%s","releases_sha":"%s","image_ref":"%s","image_digest":"%s","deployed_at":"%s","migration":"none","reason":"%s"}\n' \
    "$WWW_CN_SOURCE_SHA" "$RELEASES_SHA" "$IMAGE_REF" "$WWW_CN_IMAGE_DIGEST" "$deployed_at" "${ROLLBACK_REASON:-release}" \
    >> "$RECORD_FILE"
}

exec 7>/run/lock/leaperone-docker-deploy.lock
echo "==> Waiting for host Docker deployment lock..."
flock -x 7
echo "==> Deploying LEAPERone CN ${WWW_CN_SOURCE_SHA}..."

PREVIOUS_FILE=
if [ -s "$CURRENT_FILE" ]; then
  PREVIOUS_FILE="$(mktemp)"
  install -m 0600 "$CURRENT_FILE" "$PREVIOUS_FILE"
  trap 'rm -f "$HTML_FILE" "$PREVIOUS_FILE"' EXIT
fi

echo "==> Pulling immutable CN candidate before touching the active container..."
docker compose pull
quarantine_bootstrap_container

if ! activate_release; then
  echo "ERROR: LEAPERone CN candidate failed verification" >&2
  if [ -n "$PREVIOUS_FILE" ] && restore_previous "$PREVIOUS_FILE"; then
    echo "Previous CN release restored; the requested deployment still fails" >&2
  elif restore_bootstrap_container; then
    echo "Pre-workflow CN container restored; the requested deployment still fails" >&2
  else
    echo "No verified previous CN release could be restored" >&2
  fi
  exit 1
fi

persist_release
echo "==> LEAPERone CN ${WWW_CN_SOURCE_SHA} is healthy"
if [ -n "${BOOTSTRAP_CONTAINER:-}" ]; then
  echo "Pre-workflow fallback retained stopped as ${BOOTSTRAP_CONTAINER}"
fi
docker compose ps
