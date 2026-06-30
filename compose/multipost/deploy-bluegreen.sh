#!/bin/bash
# 蓝绿部署 multipost web（PVE LXC 200, production）。
#
# 由通用 /opt/apps/bin/deploy.sh 在探测到本文件可执行时 `exec` 调用（无参数）。
# 也可手动执行：/opt/apps/multipost/production/deploy-bluegreen.sh
#
# 端口: blue=9900  green=9910
# 镜像: 沿用 .env 的 IMAGE_TAG（现网 = latest）；`up --pull always` 拉最新构建。
#
# 范围: 只对 web 做蓝绿（零停机）。video-stt-worker 是无端口单例 worker，backend 是 PVE 唯一
#       的 cron 单例 —— 两者由主 docker-compose.yml 常驻、每次部署 recreate（瞬断可接受）。
#
# 流量架构（multipost 不经本机 nginx 的 server_name，而是经 frp + 源站 TLS 终止）：
#   multipost.app → HK:443 stream(ssl_preread,不解密) → frps:19900 → 隧道 → 本机 frpc
#     → 127.0.0.1:9443（本机 nginx multipost-local.conf，终止 TLS）→ upstream multipost_web_active
#     → web 容器(blue:9900 / green:9910)。蓝绿只切 multipost_web_active 的端口。
#
# ── 设计要点（移植自 twosomeone deploy-bluegreen.sh，已在生产验证）──────────────
#  - flock 串行化：同一时刻只允许一个部署，消除 upstream 解析→改写的 TOCTOU。
#  - preflight：起 idle 前强制校验 multipost-local.conf 存在且 proxy_pass multipost_web_active。
#  - fail-closed 解析 active 端口：upstream 块必须恰好一行 server 127.0.0.1:<port> 且 ∈ {9900,9910}。
#  - 切流原子化：备份 conf → sed 改 upstream 端口 → nginx -t → reload；任一步失败回滚并 reload、down idle。
#  - 切完经源站 9443(proxy_protocol+TLS) 端到端复验 /api/health 再停旧；复验失败自动回滚，旧色零中断。
#  - 停旧色按 compose project / legacy 容器名，不靠 `docker ps --filter publish`。
#
# ── 首次 BOOTSTRAP（人工一次性；详见 BLUEGREEN.md）──────────────────────────────
#  1) acme 签 *.multipost.app 证书到 /etc/nginx/ssl/multipost.app/（同 2some.ren）。
#  2) 装 multipost-local.conf 到 sites-enabled（listen 9443 ssl proxy_protocol + upstream 9900）。
#  3) HK: stream map 把 multipost.app/api.multipost.app 指向直透源站的 upstream；停 7443 的 L7 vhost。
#  4) frpc multipost.toml localPort 9900→9443，docker restart frpc。
#  5) 首次跑本脚本：9900 → green:9910 → 切 upstream → 停 legacy 容器。此后 blue↔green 交替。
set -euo pipefail

PROJECT_DIR=/opt/apps/multipost/production
WEB_COMPOSE="$PROJECT_DIR/docker-compose.web.yml"
WORKER_COMPOSE="$PROJECT_DIR/docker-compose.yml"
ACTIVE_CONF=/etc/nginx/sites-enabled/multipost-local.conf
LEGACY_NAME=multipost-web-production
BLUE_PORT=9900
GREEN_PORT=9910
# multipost 的 /api/health 是纯 liveness（不碰 DB/Redis/上游，~ms 返回 200），可直接做就绪探测。
HEALTH_PATH=/api/health
HEALTH_RETRIES=30
HEALTH_INTERVAL=2
OBSERVE_SECONDS=10
# 源站 TLS 终止 server（multipost-local.conf 内）的本机端口；端到端复验经此口（proxy_protocol）。
ORIGIN_PORT=9443
PUBLIC_HOSTS=(multipost.app)

# ── 部署锁（flock）：非阻塞，拿不到锁说明已有部署在跑，直接退出 ──────────────────
LOCK_FILE=/run/multipost-bluegreen.lock
{ exec 9>"$LOCK_FILE"; } 2>/dev/null || exec 9>/tmp/multipost-bluegreen.lock
if ! flock -n 9; then
  echo "ERROR: another multipost blue-green deploy is in progress (lock held); aborting." >&2
  exit 1
fi

# 直探后端：宿主有 curl 无 wget，留 wget 作可移植回退。
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

# 经源站 9443 端到端探（proxy_protocol + TLS + SNI + 路由 + 后端）。源站 listen 带 proxy_protocol，
# 故必须用 curl --haproxy-protocol 先发 PROXY 头；-k 因我们连 127.0.0.1 而证书 CN 是 multipost.app。
probe_via_origin() {
  local host="$1"
  curl -fsS -k --haproxy-protocol --max-time 8 --resolve "${host}:${ORIGIN_PORT}:127.0.0.1" \
    "https://${host}:${ORIGIN_PORT}${HEALTH_PATH}" >/dev/null 2>&1
}

cd "$PROJECT_DIR"

# ── PREFLIGHT：源站 conf 必须已 bootstrap（含 upstream + proxy_pass multipost_web_active）─────
if [ ! -f "$ACTIVE_CONF" ]; then
  echo "ERROR: $ACTIVE_CONF missing; bootstrap nginx first (see BLUEGREEN.md)." >&2; exit 1
fi
if ! grep -qE 'upstream[[:space:]]+multipost_web_active' "$ACTIVE_CONF"; then
  echo "ERROR: $ACTIVE_CONF has no 'upstream multipost_web_active' block; bootstrap incomplete." >&2; exit 1
fi
if ! grep -qE 'proxy_pass[[:space:]]+http://multipost_web_active' "$ACTIVE_CONF"; then
  echo "ERROR: $ACTIVE_CONF does not proxy_pass to multipost_web_active; bootstrap incomplete." >&2; exit 1
fi

# 1. fail-closed 解析 active 端口（^server 开头的正则本就排除注释行）
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
echo "==> active=${current_port} -> deploying idle=${idle_color}:${idle_port}"

# 2. 起 idle 色（active 色不受影响）。COLOR/WEB_PORT 经 shell 覆盖 .env 做 compose 变量替换；
#    IMAGE_TAG 仍由 .env 提供，--pull always 拉最新构建。
COLOR="$idle_color" WEB_PORT="$idle_port" \
  docker compose -p "multipost-web-${idle_color}" -f "$WEB_COMPOSE" up -d --pull always

# 3. 探 idle 后端健康
ok=0
for _ in $(seq 1 "$HEALTH_RETRIES"); do
  if probe "http://127.0.0.1:${idle_port}${HEALTH_PATH}"; then ok=1; break; fi
  sleep "$HEALTH_INTERVAL"
done
if [ "$ok" != 1 ]; then
  echo "ERROR: idle ${idle_color}:${idle_port} failed health check; aborting (active untouched)." >&2
  docker compose -p "multipost-web-${idle_color}" -f "$WEB_COMPOSE" down || true
  exit 1
fi
echo "==> idle ${idle_color}:${idle_port} healthy"

# 4. 原子切 nginx upstream
backup="$(mktemp)"
cp -a "$ACTIVE_CONF" "$backup"
revert_conf_reload() { cp -a "$backup" "$ACTIVE_CONF"; nginx -s reload 2>/dev/null || true; }
down_idle() { docker compose -p "multipost-web-${idle_color}" -f "$WEB_COMPOSE" down || true; }
sed -i -E "s#^([[:space:]]*server[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${idle_port}#" "$ACTIVE_CONF"
if ! nginx -t 2>/dev/null; then
  echo "ERROR: nginx -t failed after switching upstream; reverting." >&2
  revert_conf_reload; rm -f "$backup"; down_idle; exit 1
fi
if ! nginx -s reload; then
  echo "ERROR: nginx reload failed; reverting." >&2
  revert_conf_reload; rm -f "$backup"; down_idle; exit 1
fi
echo "==> switched active -> ${idle_color}:${idle_port}"

# 5. 切完端到端复验（经 nginx 探主站）；失败则回滚到旧端口、保留旧色、abort
sleep "$OBSERVE_SECONDS"
verify_ok=1
if ! probe "http://127.0.0.1:${idle_port}${HEALTH_PATH}"; then
  echo "ERROR: idle backend ${idle_port} unhealthy after switch." >&2; verify_ok=0
fi
for host in "${PUBLIC_HOSTS[@]}"; do
  if ! probe_via_origin "$host"; then
    echo "ERROR: post-switch probe via origin :${ORIGIN_PORT} failed for ${host}." >&2; verify_ok=0
  fi
done
if [ "$verify_ok" != 1 ]; then
  echo "ERROR: post-switch verification failed; rolling upstream back to ${current_port}." >&2
  sed -i -E "s#^([[:space:]]*server[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${current_port}#" "$ACTIVE_CONF"
  rm -f "$backup"
  if nginx -t 2>/dev/null && nginx -s reload; then
    down_idle; exit 1
  fi
  echo "CRITICAL: rollback reload failed; upstream file set to ${current_port} but nginx not reloaded. Leaving idle ${idle_color}:${idle_port} UP to avoid outage. Manual: fix nginx config, then 'nginx -s reload'." >&2
  exit 1
fi
rm -f "$backup"
echo "==> verified: multipost.app healthy via nginx on ${idle_color}:${idle_port}"

# 6. 停旧色（按 compose project；首迁额外停 legacy 单容器）。均保留容器供回滚。
echo "==> stopping previous color project multipost-web-${old_color} (if any)"
docker compose -p "multipost-web-${old_color}" -f "$WEB_COMPOSE" stop 2>/dev/null || true
if [ "$(docker inspect -f '{{.State.Running}}' "$LEGACY_NAME" 2>/dev/null || echo false)" = "true" ]; then
  echo "==> stopping legacy container ${LEGACY_NAME} (first migration)"
  docker stop "$LEGACY_NAME" >/dev/null 2>&1 || true
fi

# 7. 常驻 worker + backend(PVE 单例)：拉新镜像并保证在跑。--profile backend 启用 backend。
#    不加 --remove-orphans：避免误删尚保留作回滚的 legacy web 容器（multipost-web-production）。
echo "==> ensuring resident workers + backend are up to date"
docker compose -f "$WORKER_COMPOSE" --profile backend up -d --pull always

# 8. 跑可执行的 post-deploy scripts/*（如带宽限制脚本）。
if [ -d "$PROJECT_DIR/scripts" ]; then
  echo "==> Running post-deploy scripts..."
  for script in "$PROJECT_DIR"/scripts/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      echo "--> $(basename "$script")"; "$script"
    fi
  done
fi

# 9. 清理悬空镜像（与 legacy 行为一致）
docker image prune -f >/dev/null 2>&1 || true

echo "==> deploy complete: active=${idle_color}:${idle_port}; old (:${current_port}) stopped (kept for rollback)"
echo "    rollback: start 旧色/${LEGACY_NAME} -> 探 :${current_port} 健康 -> sed upstream 端口改回 ${current_port} -> nginx -t && nginx -s reload"
