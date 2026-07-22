#!/bin/bash
# 通用部署脚本，源在 leaperone-releases/scripts/deploy.sh。
# CI 必须同步当前 checkout 中的脚本后再调用：deploy.sh <project> <env> [active|cold]
set -euo pipefail

PROJECT="${1:?Usage: deploy.sh <project> <env> [active|cold]}"
ENV="${2:?Usage: deploy.sh <project> <env> [active|cold]}"
MODE="${3:-active}"
: "${APP_DEPLOY_ROOT:?APP_DEPLOY_ROOT must be supplied by the deployment environment}"

# 严格校验 project/env，杜绝 / 、.. 等路径穿越（本脚本以 root 跑、会 exec 目录内文件）。
case "$PROJECT" in ""|*[!a-z0-9_-]*) echo "ERROR: invalid PROJECT '$PROJECT'" >&2; exit 1;; esac
case "$ENV"     in ""|*[!a-z0-9_-]*) echo "ERROR: invalid ENV '$ENV'" >&2; exit 1;; esac
case "$MODE"    in active|cold) :;; *) echo "ERROR: invalid deployment mode '$MODE'" >&2; exit 1;; esac
if [ "$#" -gt 3 ]; then
  echo "ERROR: too many arguments; usage: deploy.sh <project> <env> [active|cold]" >&2
  exit 1
fi

APP_DIR="${APP_DEPLOY_ROOT}/${PROJECT}/${ENV}"
export PROJECT_DIR="$APP_DIR"

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: ${APP_DIR} does not exist" >&2
  exit 1
fi

if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
  echo "ERROR: ${APP_DIR}/docker-compose.yml not found" >&2
  exit 1
fi

if [ ! -f "$APP_DIR/.env" ]; then
  echo "ERROR: ${APP_DIR}/.env not found (create it with required env vars)" >&2
  exit 1
fi

if [ "$PROJECT" = "leaperone" ]; then
  if [ ! -f "$APP_DIR/.env.api" ]; then
    echo "ERROR: ${APP_DIR}/.env.api not found; LEAPERone is an API-only compose project" >&2
    exit 1
  fi
fi

cd "$APP_DIR"

# Cold mode only refreshes a stopped, non-restarting container set. It deliberately
# skips active preflight, blue-green routing, health probes and post-deploy hooks:
# those belong to an explicit activation, never to routine image staging. A
# side-effect-free prestage.sh may validate cold-stage assets before any pull.
if [ "$MODE" = "cold" ]; then
  if [ -e "$APP_DIR/deploy-bluegreen.sh" ]; then
    echo "ERROR: cold deployment requires a dedicated non-blue-green manifest" >&2
    exit 1
  fi

  DOCKER_DEPLOY_LOCK="${LEAPERONE_DOCKER_DEPLOY_LOCK:-/run/lock/leaperone-docker-deploy.lock}"
  exec 7>"$DOCKER_DEPLOY_LOCK"
  echo "==> Waiting for host Docker deployment lock..."
  flock -x 7
  echo "==> Acquired host Docker deployment lock"

  COLD_DIAGNOSTIC="$APP_DIR/.cold-stage-diagnostic"
  COLD_OVERRIDE=""
  COLD_SUCCEEDED=0
  install -m 0600 /dev/null "$COLD_DIAGNOSTIC" 2>/dev/null || {
    echo "ERROR: unable to initialize private cold-stage diagnostics" >&2
    exit 1
  }
  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cold_cleanup() {
    [ -z "$COLD_OVERRIDE" ] || rm -f "$COLD_OVERRIDE"
    if [ "$COLD_SUCCEEDED" -eq 1 ]; then
      rm -f "$COLD_DIAGNOSTIC"
    fi
  }
  trap cold_cleanup EXIT

  if ! docker compose config --quiet >"$COLD_DIAGNOSTIC" 2>&1; then
    echo "ERROR: cold-stage Compose validation failed; private diagnostics retained on host" >&2
    exit 1
  fi
  if [ -f "$APP_DIR/prestage.sh" ]; then
    if [ ! -x "$APP_DIR/prestage.sh" ]; then
      echo "ERROR: prestage.sh exists but is not executable" >&2
      exit 1
    fi
    echo "==> Running cold-stage preflight..."
    if ! "$APP_DIR/prestage.sh" >"$COLD_DIAGNOSTIC" 2>&1; then
      echo "ERROR: cold-stage preflight failed; private diagnostics retained on host" >&2
      exit 1
    fi
  fi

  # Query through Compose so detection follows its resolved project name rather
  # than a working-directory label that can change across symlinks or relocations.
  if ! existing_output="$(docker compose ps -aq --all 2>"$COLD_DIAGNOSTIC")"; then
    echo "ERROR: unable to inspect cold-stage containers; private diagnostics retained on host" >&2
    exit 1
  fi
  existing_ids=()
  if [ -n "$existing_output" ]; then
    mapfile -t existing_ids <<<"$existing_output"
  fi
  for container_id in "${existing_ids[@]}"; do
    if ! existing_running="$(docker inspect --format '{{.State.Running}}' "$container_id" 2>"$COLD_DIAGNOSTIC")"; then
      echo "ERROR: unable to inspect existing container state; private diagnostics retained on host" >&2
      exit 1
    fi
    if [ "$existing_running" = "true" ]; then
      echo "ERROR: cold deployment refuses to change a running container set" >&2
      exit 1
    fi
  done

  # Represent restart=no in the Compose model itself. This keeps partially
  # created containers safe if create fails and makes a later active config
  # change visible to Compose instead of mutating policy out of band.
  COLD_OVERRIDE="$(mktemp)"
  if ! service_output="$(docker compose config --services 2>"$COLD_DIAGNOSTIC")"; then
    echo "ERROR: unable to resolve cold-stage services; private diagnostics retained on host" >&2
    exit 1
  fi
  {
    echo 'services:'
    while IFS= read -r service; do
      case "$service" in
        ""|*[!a-zA-Z0-9_.-]*)
          echo "ERROR: invalid Compose service name" >&2
          exit 1
          ;;
      esac
      printf '  %s:\n    restart: "no"\n' "$service"
    done <<<"$service_output"
  } > "$COLD_OVERRIDE"
  COLD_COMPOSE=(docker compose -f "$APP_DIR/docker-compose.yml" -f "$COLD_OVERRIDE")
  if ! "${COLD_COMPOSE[@]}" config --quiet >"$COLD_DIAGNOSTIC" 2>&1; then
    echo "ERROR: cold-stage override validation failed; private diagnostics retained on host" >&2
    exit 1
  fi

  echo "==> Pulling images for cold deployment..."
  if ! "${COLD_COMPOSE[@]}" pull --quiet >"$COLD_DIAGNOSTIC" 2>&1; then
    echo "ERROR: cold-stage image pull failed; private diagnostics retained on host" >&2
    exit 1
  fi

  echo "==> Creating stopped containers..."
  if ! install -m 0600 /dev/null "$APP_DIR/.cold-staged" 2>"$COLD_DIAGNOSTIC"; then
    echo "ERROR: unable to record cold-stage state; private diagnostics retained on host" >&2
    exit 1
  fi
  if ! "${COLD_COMPOSE[@]}" create --force-recreate >"$COLD_DIAGNOSTIC" 2>&1; then
    echo "ERROR: cold-stage container creation failed; private diagnostics retained on host" >&2
    exit 1
  fi

  if ! staged_output="$("${COLD_COMPOSE[@]}" ps -aq --all 2>"$COLD_DIAGNOSTIC")"; then
    echo "ERROR: unable to inspect staged containers; private diagnostics retained on host" >&2
    exit 1
  fi
  staged_ids=()
  if [ -n "$staged_output" ]; then
    mapfile -t staged_ids <<<"$staged_output"
  fi
  if [ "${#staged_ids[@]}" -eq 0 ]; then
    echo "ERROR: cold deployment did not create any containers" >&2
    exit 1
  fi

  for container_id in "${staged_ids[@]}"; do
    if ! running="$(docker inspect --format '{{.State.Running}}' "$container_id" 2>"$COLD_DIAGNOSTIC")"; then
      echo "ERROR: unable to inspect staged container state; private diagnostics retained on host" >&2
      exit 1
    fi
    if ! restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id" 2>"$COLD_DIAGNOSTIC")"; then
      echo "ERROR: unable to inspect staged restart policy; private diagnostics retained on host" >&2
      exit 1
    fi
    if [ "$running" != "false" ] || [ "$restart_policy" != "no" ]; then
      echo "ERROR: cold deployment invariant failed" >&2
      exit 1
    fi
  done

  COLD_SUCCEEDED=1
  echo "==> Cold deployment complete: ${#staged_ids[@]} container(s) stopped with restart disabled"
  exit 0
fi

# Project-specific preflight runs before any image pull or container change.
# If present it must be executable; silently skipping a mode-drifted safety
# check would make the deployment less safe than the repository declares.
if [ -f "$APP_DIR/preflight.sh" ]; then
  if [ ! -x "$APP_DIR/preflight.sh" ]; then
    echo "ERROR: $APP_DIR/preflight.sh exists but is not executable" >&2
    exit 1
  fi
  echo "==> Running preflight for ${PROJECT}/${ENV}..."
  "$APP_DIR/preflight.sh"
fi

# ── 蓝绿 opt-in ─────────────────────────────────────────────────────────────
# 某个 project/env 若随 compose 一起 scp 来一份可执行的 deploy-bluegreen.sh，则把部署
# 完全交给它（拉空闲色 → 健康探测 → 原子切 nginx upstream → 停旧色，零停机）。
# 没有这个文件的 project（cap / multipost 等）保持下面的 legacy 停机式替换，行为不变。
# fail-closed：文件存在却不可执行（mode drift）→ 直接报错中止，绝不静默回落 legacy——
# 否则 legacy 路径会用蓝绿 compose 起新容器去抢已被占用的端口而失败。
if [ -f "$APP_DIR/deploy-bluegreen.sh" ]; then
  if [ -f "$APP_DIR/.cold-staged" ]; then
    echo "ERROR: a cold-staged blue-green project requires its explicit activation procedure" >&2
    exit 1
  fi
  if [ -x "$APP_DIR/deploy-bluegreen.sh" ]; then
    echo "==> Blue-green deployer detected for ${PROJECT}/${ENV}; delegating to deploy-bluegreen.sh"
    exec "$APP_DIR/deploy-bluegreen.sh"
  fi
  echo "ERROR: $APP_DIR/deploy-bluegreen.sh exists but is not executable; refusing legacy fallback. Run chmod +x and retry." >&2
  exit 1
fi

# Every project on a host shares one Docker daemon and containerd content
# store. Blue-green scripts acquire the same lock themselves so their direct
# manual entry points remain safe and no inherited descriptor is overwritten.
DOCKER_DEPLOY_LOCK="${LEAPERONE_DOCKER_DEPLOY_LOCK:-/run/lock/leaperone-docker-deploy.lock}"
exec 7>"$DOCKER_DEPLOY_LOCK"
echo "==> Waiting for host Docker deployment lock..."
flock -x 7
echo "==> Acquired host Docker deployment lock"

echo "==> Pulling images for ${PROJECT}/${ENV}..."
docker compose config --quiet
docker compose pull

echo "==> Starting services and waiting for health checks..."
UP_ARGS=(-d --remove-orphans --wait --wait-timeout 180)
if [ -f "$APP_DIR/.cold-staged" ]; then
  UP_ARGS+=(--force-recreate)
fi
docker compose up "${UP_ARGS[@]}"
rm -f "$APP_DIR/.cold-staged"

if [ "$PROJECT" = "leaperone" ]; then
  # API releases never own Nginx. This also fail-safes overwrite-only server
  # syncs where an installer deleted from Git might still exist on disk.
  echo "==> LEAPERone API-only deploy: post-deploy scripts are disabled"
elif [ -d "$APP_DIR/scripts" ]; then
  echo "==> Running post-deploy scripts..."
  for script in "$APP_DIR"/scripts/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      echo "--> $(basename "$script")"
      "$script"
    fi
  done
fi

echo "==> Deploy ${PROJECT}/${ENV} complete"
docker compose ps
