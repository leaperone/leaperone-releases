#!/bin/bash
# NIMEI Germany blue/green deploy. Readiness intentionally uses /api/ready,
# which must validate the required NIMEI database schema rather than liveness.
set -euo pipefail

PROJECT_DIR=/opt/apps/nimei/production
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ACTIVE_CONF=/etc/nginx/sites-enabled/nimei-local.conf
BLUE_PORT=9811
GREEN_PORT=9812
READY_PATH=/api/ready
READY_RETRIES=45
READY_INTERVAL=2
OBSERVE_SECONDS=10
ORIGIN_PORT=443

: "${IMAGE_REF:?NIMEI deploy requires immutable IMAGE_REF}"
: "${IMAGE_DIGEST:?NIMEI deploy requires IMAGE_DIGEST}"
: "${IMAGE_SOURCE_SHA:?NIMEI deploy requires IMAGE_SOURCE_SHA}"
: "${DEPLOY_IMAGE_REF:?NIMEI deploy requires digest-pinned DEPLOY_IMAGE_REF}"
[[ "$IMAGE_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  echo "ERROR: invalid NIMEI IMAGE_SOURCE_SHA" >&2
  exit 1
}
[ "$IMAGE_REF" = "registry.cn-hongkong.aliyuncs.com/leaperone/nimei:web-${IMAGE_SOURCE_SHA}" ] || {
  echo "ERROR: invalid immutable NIMEI IMAGE_REF" >&2
  exit 1
}
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "ERROR: invalid NIMEI IMAGE_DIGEST" >&2
  exit 1
}
[ "$DEPLOY_IMAGE_REF" = "${IMAGE_REF%:*}@${IMAGE_DIGEST}" ] || {
  echo "ERROR: NIMEI DEPLOY_IMAGE_REF is not the expected RepoDigest" >&2
  exit 1
}

LOCK_FILE=/run/nimei-bluegreen.lock
{ exec 9>"$LOCK_FILE"; } 2>/dev/null || exec 9>/tmp/nimei-bluegreen.lock
if ! flock -n 9; then
  echo "ERROR: another NIMEI blue-green deploy is in progress" >&2
  exit 1
fi

probe() {
  curl -fsS --max-time 8 "$1" >/dev/null 2>&1
}

probe_origin() {
  curl -fsSk --max-time 8 --resolve "nimei.app:${ORIGIN_PORT}:127.0.0.1" \
    "https://nimei.app:${ORIGIN_PORT}${READY_PATH}" >/dev/null 2>&1
}

mapfile -t server_ports < <(grep -oE '^[[:space:]]*server[[:space:]]+127\.0\.0\.1:[0-9]+' "$ACTIVE_CONF" \
  | grep -oE '[0-9]+$' || true)
if [ "${#server_ports[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one active NIMEI upstream port" >&2
  exit 1
fi

current_port="${server_ports[0]}"
case "$current_port" in
  "$BLUE_PORT") idle_color=green; idle_port=$GREEN_PORT; old_color=blue ;;
  "$GREEN_PORT") idle_color=blue; idle_port=$BLUE_PORT; old_color=green ;;
  *) echo "ERROR: active NIMEI port $current_port is not 9811/9812" >&2; exit 1 ;;
esac

old_healthy=false
if probe "http://127.0.0.1:${current_port}${READY_PATH}"; then
  old_healthy=true
fi

cd "$PROJECT_DIR"
echo "==> active=${current_port}; deploying ${idle_color}:${idle_port}"
COLOR="$idle_color" WEB_PORT="$idle_port" \
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" up -d --pull always

ready=false
for _ in $(seq 1 "$READY_RETRIES"); do
  if probe "http://127.0.0.1:${idle_port}${READY_PATH}"; then
    ready=true
    break
  fi
  sleep "$READY_INTERVAL"
done
if [ "$ready" != true ]; then
  echo "ERROR: idle NIMEI ${idle_color}:${idle_port} failed readiness" >&2
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
fi

container_id="$(COLOR="$idle_color" WEB_PORT="$idle_port" \
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" ps -q web)"
test -n "$container_id"
expected_image="${DEPLOY_IMAGE_REF:-${REGISTRY_HOST:-registry.cn-hongkong.aliyuncs.com}/leaperone/nimei:${IMAGE_TAG:-latest}}"
actual_image="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
[ "$actual_image" = "$expected_image" ] || {
  echo "ERROR: idle NIMEI image mismatch: expected $expected_image, got $actual_image" >&2
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
}
[ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.source-sha"}}' "$container_id")" = "$IMAGE_SOURCE_SHA" ] || {
  echo "ERROR: idle NIMEI source SHA label mismatch" >&2
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
}
[ "$(docker inspect --format '{{index .Config.Labels "com.leaperone.image-digest"}}' "$container_id")" = "$IMAGE_DIGEST" ] || {
  echo "ERROR: idle NIMEI digest label mismatch" >&2
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
}
expected_repo_digest="${IMAGE_REF%:*}@${IMAGE_DIGEST}"
container_image_id="$(docker inspect --format '{{.Image}}' "$container_id")"
if ! docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$container_image_id" \
  | grep -Fxq "$expected_repo_digest"; then
  echo "ERROR: idle NIMEI is not running expected RepoDigest $expected_repo_digest" >&2
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
fi

backup="$(mktemp)"
cp -a "$ACTIVE_CONF" "$backup"
down_idle() {
  docker compose -p "nimei-web-${idle_color}" -f "$COMPOSE_FILE" down || true
}
restore_old() {
  cp -a "$backup" "$ACTIVE_CONF"
  nginx -t >/dev/null 2>&1 && nginx -s reload
}

sed -i -E "s#^([[:space:]]*server[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${idle_port}#" "$ACTIVE_CONF"
if ! nginx -t; then
  restore_old || true
  rm -f "$backup"
  down_idle
  exit 1
fi
if ! nginx -s reload; then
  restore_old || true
  rm -f "$backup"
  down_idle
  exit 1
fi

sleep "$OBSERVE_SECONDS"
if ! probe "http://127.0.0.1:${idle_port}${READY_PATH}" || ! probe_origin; then
  echo "ERROR: NIMEI failed post-switch readiness" >&2
  if [ "$old_healthy" = true ]; then
    if restore_old; then
      rm -f "$backup"
      down_idle
      exit 1
    fi
    echo "CRITICAL: could not restore the old NIMEI upstream" >&2
  else
    echo "ERROR: bootstrap had no ready old color; leaving idle up for diagnosis" >&2
  fi
  rm -f "$backup"
  exit 1
fi
rm -f "$backup"

docker compose -p "nimei-web-${old_color}" -f "$COMPOSE_FILE" stop 2>/dev/null || true
docker image prune -f >/dev/null 2>&1 || true
echo "==> NIMEI active=${idle_color}:${idle_port}; /api/ready verified through Germany Nginx"
