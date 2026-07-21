#!/bin/bash
# 蓝绿部署 twosomeone backend（PVE LXC 200, production）。
#
# 由通用部署入口调用（无参数）。
#
# 端口: blue=3003  green=3013（host 端口 → 容器 3001）。
# 镜像: 沿用 .env 的 IMAGE_TAG（现网 = backend-main-latest）；`up --pull always` 拉最新构建。
#
# ── 设计要点（沿用已验证的 web deploy-bluegreen.sh）────────────────────────────
#  - flock 串行化：独立项目锁防止 backend 重入；宿主 Docker 锁避免跨项目
#    同时 pull/switch 导致 containerd content-store 竞争。
#  - preflight：起 idle 前校验 backend.2some.ren.conf 与内部监听 conf 都已指
#    twosomeone_backend_active 且无残留 127.0.0.1:3003/3013,否则 abort。
#  - fail-closed 解析 active 端口：upstream 必须恰好一行 server 127.0.0.1:<port> 且 ∈ {3003,3013}。
#  - 切流原子化 + 切后经 nginx 端到端复验 backend.2some.ren /ready,失败回滚保留旧色。
#  - 停旧色按 compose project / legacy 容器名(不靠 docker --filter publish)。
#  - WS 长连接在切流停旧色时断开,客户端自动重连到新色(PG LISTEN/NOTIFY 跨实例投递,无 sticky)。
#
# ── 首次 BOOTSTRAP（人工一次性,迁移前做）──────────────────────────────────
#  1) 装 00-twosomeone-backend-upstream.conf(server 127.0.0.1:3003=legacy)+ 10-twosomeone-internal.conf。
#  2) backend.2some.ren.conf 的 `proxy_pass http://127.0.0.1:3003` 改成 `http://twosomeone_backend_active`。
#  3) host .env:web BACKEND_BASE_URL→:3030、backend WEB_BASE_URL→:3031;recreate web。
#  4) nginx -t && reload。此刻 active=3003=legacy,对外无变化。
#  5) 首次跑本脚本:active=3003 → green:3013 → 切 upstream → 停 legacy。此后 blue↔green 交替。
set -euo pipefail

: "${PROJECT_DIR:?PROJECT_DIR must be supplied by the deployment environment}"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ACTIVE_CONF=/etc/nginx/sites-enabled/00-twosomeone-backend-upstream.conf
LEGACY_NAME=twosomeone-backend-production
BLUE_PORT=3003
GREEN_PORT=3013
# /ready 同时检查 runtime、消息总线和数据库，避免未就绪实例接流量。
READY_PATH=/ready
HEALTH_RETRIES=30
HEALTH_INTERVAL=2
OBSERVE_SECONDS=10
# 路由到 backend 的所有 conf 都要已指 upstream(backend.2some.ren 公网 + 内部 :3030 监听)。
VHOSTS=(/etc/nginx/sites-enabled/backend.2some.ren.conf /etc/nginx/sites-enabled/10-twosomeone-internal.conf)
PUBLIC_HOSTS=(backend.2some.ren)

# ── 部署锁(flock,backend 专用) ──────────────────────────────────────────────
LOCK_FILE=/run/twosomeone-backend-bluegreen.lock
{ exec 9>"$LOCK_FILE"; } 2>/dev/null || exec 9>/tmp/twosomeone-backend-bluegreen.lock
if ! flock -n 9; then
  echo "ERROR: another twosomeone-backend blue-green deploy is in progress (lock held); aborting." >&2
  exit 1
fi

HOST_DOCKER_LOCK="${LEAPERONE_DOCKER_DEPLOY_LOCK:-/run/lock/leaperone-docker-deploy.lock}"
exec 7>"$HOST_DOCKER_LOCK"
echo "==> Waiting for host Docker deployment lock..."
flock -x 7
echo "==> Acquired host Docker deployment lock"

probe() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 "$url" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 8 -O /dev/null "$url" 2>/dev/null
  else
    echo "ERROR: neither curl nor wget on host for health probe" >&2
    return 2
  fi
}

probe_via_nginx() {
  local host="$1"
  curl -fsS --max-time 8 --resolve "${host}:443:127.0.0.1" "https://${host}${READY_PATH}" >/dev/null 2>&1
}

cd "$PROJECT_DIR"

# ── PREFLIGHT：路由到 backend 的 conf 必须已指 upstream,无残留直连旧端口 ─────────
for vh in "${VHOSTS[@]}"; do
  if [ ! -f "$vh" ]; then
    echo "ERROR: conf $vh missing; bootstrap nginx first (see header)." >&2; exit 1
  fi
  if ! grep -qE 'proxy_pass[[:space:]]+http://twosomeone_backend_active' "$vh"; then
    echo "ERROR: $vh does not reference twosomeone_backend_active; bootstrap incomplete." >&2; exit 1
  fi
  if grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:(3003|3013)' "$vh"; then
    echo "ERROR: $vh still has a direct 127.0.0.1:3003/3013 proxy_pass; bootstrap incomplete." >&2; exit 1
  fi
done

# 1. fail-closed 解析 active 端口
mapfile -t server_ports < <(grep -oE '^[[:space:]]*server[[:space:]]+127\.0\.0\.1:[0-9]+' "$ACTIVE_CONF" \
  | grep -oE '[0-9]+$' || true)
if [ "${#server_ports[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly 1 'server 127.0.0.1:<port>' line in $ACTIVE_CONF, got ${#server_ports[@]}." >&2
  exit 1
fi
current_port="${server_ports[0]}"
case "$current_port" in
  "$BLUE_PORT")  idle_color=green; idle_port=$GREEN_PORT; old_color=blue  ;;
  "$GREEN_PORT") idle_color=blue;  idle_port=$BLUE_PORT;  old_color=green ;;
  *) echo "ERROR: active port '$current_port' not in {$BLUE_PORT,$GREEN_PORT}; bootstrap first." >&2; exit 1 ;;
esac
echo "==> active=${current_port} → deploying idle=${idle_color}:${idle_port}"

# 2. 起 idle 色(active 色不受影响)。COLOR/BACKEND_PORT 经 shell 覆盖 .env 做 compose 变量替换。
COLOR="$idle_color" BACKEND_PORT="$idle_port" \
  docker compose -p "twosomeone-backend-${idle_color}" -f "$COMPOSE_FILE" up -d --pull always

# 3. 探 idle 后端健康
ok=0
for _ in $(seq 1 "$HEALTH_RETRIES"); do
  if probe "http://127.0.0.1:${idle_port}${READY_PATH}"; then ok=1; break; fi
  sleep "$HEALTH_INTERVAL"
done
if [ "$ok" != 1 ]; then
  echo "ERROR: idle ${idle_color}:${idle_port} failed health check; aborting (active untouched)." >&2
  docker compose -p "twosomeone-backend-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
fi
echo "==> idle ${idle_color}:${idle_port} healthy"

# 3b. 校验 idle 色能经 WEB_BASE_URL 反调 web(/ready 不碰 WEB_BASE_URL,光探它会漏掉
#     backend→web 断裂:stale env / :3031 监听坏 / web upstream 异常)。从 idle 容器内打
#     $WEB_BASE_URL/api/internal/(带斜杠,匹配监听 location)。任何 HTTP 码(401/404/405…)
#     都=链路通(env→:3031→web upstream→web);000/空=不通,切流前就 abort、不停旧色。
web_reach="$(docker compose -p "twosomeone-backend-${idle_color}" -f "$COMPOSE_FILE" exec -T backend \
  sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 8 "${WEB_BASE_URL%/}/api/internal/" 2>/dev/null' 2>/dev/null || echo 000)"
if [ -z "$web_reach" ] || [ "$web_reach" = "000" ]; then
  echo "ERROR: idle backend cannot reach web via WEB_BASE_URL (got '${web_reach:-empty}'); backend→web would be broken. Aborting before switch." >&2
  docker compose -p "twosomeone-backend-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
fi
echo "==> idle backend → web reachable via WEB_BASE_URL (HTTP ${web_reach})"

# 4. 原子切 nginx upstream
backup="$(mktemp)"
cp -a "$ACTIVE_CONF" "$backup"
revert_conf_reload() { cp -a "$backup" "$ACTIVE_CONF"; nginx -s reload 2>/dev/null || true; }
down_idle() { docker compose -p "twosomeone-backend-${idle_color}" -f "$COMPOSE_FILE" down || true; }
sed -i -E "s#^([[:space:]]*server[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${idle_port}#" "$ACTIVE_CONF"
if ! nginx -t 2>/dev/null; then
  echo "ERROR: nginx -t failed after switching upstream; reverting." >&2
  revert_conf_reload; rm -f "$backup"; down_idle; exit 1
fi
if ! nginx -s reload; then
  echo "ERROR: nginx reload failed; reverting." >&2
  revert_conf_reload; rm -f "$backup"; down_idle; exit 1
fi
echo "==> switched active → ${idle_color}:${idle_port}"

# 5. 切完端到端复验(经 nginx 探 backend.2some.ren /ready);失败回滚到旧端口、保留旧色、abort
sleep "$OBSERVE_SECONDS"
verify_ok=1
if ! probe "http://127.0.0.1:${idle_port}${READY_PATH}"; then
  echo "ERROR: idle backend ${idle_port} unhealthy after switch." >&2; verify_ok=0
fi
for host in "${PUBLIC_HOSTS[@]}"; do
  if ! probe_via_nginx "$host"; then
    echo "ERROR: post-switch probe via nginx failed for ${host}." >&2; verify_ok=0
  fi
done
if [ "$verify_ok" != 1 ]; then
  echo "ERROR: post-switch verification failed; rolling upstream back to ${current_port}." >&2
  sed -i -E "s#^([[:space:]]*server[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${current_port}#" "$ACTIVE_CONF"
  rm -f "$backup"
  if nginx -t 2>/dev/null && nginx -s reload; then
    down_idle; exit 1
  fi
  echo "CRITICAL: rollback reload failed; upstream set to ${current_port} but nginx not reloaded. Leaving idle ${idle_color}:${idle_port} UP to avoid outage. Manual: fix nginx, then 'nginx -s reload'." >&2
  exit 1
fi
rm -f "$backup"
echo "==> verified: backend.2some.ren healthy via nginx on ${idle_color}:${idle_port}"

# 6. 停旧色(按 compose project;首迁额外停 legacy 单容器)。均保留容器供回滚。
# -t 110 给足 backend 优雅停机(worker 抽干最长 ~100s),避免在途 worker 被 SIGKILL。
echo "==> stopping previous color project twosomeone-backend-${old_color} (if any)"
docker compose -p "twosomeone-backend-${old_color}" -f "$COMPOSE_FILE" stop -t 110 2>/dev/null || true
if [ "$(docker inspect -f '{{.State.Running}}' "$LEGACY_NAME" 2>/dev/null || echo false)" = "true" ]; then
  echo "==> stopping legacy container ${LEGACY_NAME} (first migration)"
  docker stop -t 110 "$LEGACY_NAME" >/dev/null 2>&1 || true
fi

# 7. 与 legacy deploy.sh 一致：跑可执行的 post-deploy scripts/*（当前无,留作未来）
if [ -d "$PROJECT_DIR/scripts" ]; then
  echo "==> Running post-deploy scripts..."
  for script in "$PROJECT_DIR"/scripts/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      echo "--> $(basename "$script")"; "$script"
    fi
  done
fi

# 8. 清理悬空镜像
docker image prune -f >/dev/null 2>&1 || true

echo "==> deploy complete: active=${idle_color}:${idle_port}; old (:${current_port}) stopped (kept for rollback)"
echo "    rollback: docker (compose) start 旧色/${LEGACY_NAME} → 探 :${current_port}/ready（旧镜像无该路由时用 /health）→ sed upstream 端口改回 ${current_port} → nginx -t && nginx -s reload"
