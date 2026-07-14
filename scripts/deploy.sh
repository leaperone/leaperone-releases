#!/bin/bash
# 通用部署脚本，源在 leaperone-releases/scripts/deploy.sh。
# CI 必须同步当前 checkout 中的脚本后再调用：deploy.sh <project> <env>
set -euo pipefail

PROJECT="${1:?Usage: deploy.sh <project> <env>}"
ENV="${2:?Usage: deploy.sh <project> <env>}"

# 严格校验 project/env，杜绝 / 、.. 等路径穿越（本脚本以 root 跑、会 exec 目录内文件）。
case "$PROJECT" in ""|*[!a-z0-9_-]*) echo "ERROR: invalid PROJECT '$PROJECT'" >&2; exit 1;; esac
case "$ENV"     in ""|*[!a-z0-9_-]*) echo "ERROR: invalid ENV '$ENV'" >&2; exit 1;; esac

APP_DIR="/opt/apps/${PROJECT}/${ENV}"

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
# 没有这个文件的 project（cap / dokilove / multipost …）保持下面的 legacy 停机式替换，行为不变。
# fail-closed：文件存在却不可执行（mode drift）→ 直接报错中止，绝不静默回落 legacy——
# 否则 legacy 路径会用蓝绿 compose 起新容器去抢已被占用的端口而失败。
if [ -f "$APP_DIR/deploy-bluegreen.sh" ]; then
  if [ -x "$APP_DIR/deploy-bluegreen.sh" ]; then
    echo "==> Blue-green deployer detected for ${PROJECT}/${ENV}; delegating to deploy-bluegreen.sh"
    exec "$APP_DIR/deploy-bluegreen.sh"
  fi
  echo "ERROR: $APP_DIR/deploy-bluegreen.sh exists but is not executable; refusing legacy fallback. Run chmod +x and retry." >&2
  exit 1
fi

echo "==> Pulling images for ${PROJECT}/${ENV}..."
docker compose config --quiet
docker compose pull

echo "==> Starting services and waiting for health checks..."
docker compose up -d --remove-orphans --wait --wait-timeout 180

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
