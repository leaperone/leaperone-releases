#!/bin/bash
# 蓝绿部署 twosomeone web（PVE LXC 200, production）。
#
# 由通用 /opt/apps/bin/deploy.sh 在探测到本文件可执行时 `exec` 调用（无参数）。
# 也可手动执行：/opt/apps/twosomeone/production/deploy-bluegreen.sh
#
# 端口: blue=3000  green=3010
# 镜像: 沿用 .env 的 IMAGE_TAG（现网 = web-main-latest）；`up --pull always` 拉最新构建。
#
# ── 设计要点（含 codex VALIDATE + 三方 REVIEW 修订）────────────────────────────
#  - flock 串行化：同一时刻只允许一个部署，消除 upstream 解析→改写的 TOCTOU。
#  - preflight：起 idle 前强制校验两个 vhost 都已指 twosomeone_web_active 且无残留
#    127.0.0.1:3000/3010，否则 abort——否则切 upstream 后某 vhost 仍直连旧端口，停旧色即 5xx。
#  - fail-closed 解析 active 端口：upstream 必须恰好一行 server 127.0.0.1:<port> 且 ∈ {3000,3010}。
#  - 切流原子化：备份 upstream → sed 改端口 → nginx -t → reload；任一步失败回滚 conf 并 reload、down idle。
#  - 切完**经 nginx 端到端复验**（2some.ren + api.2some.ren 的 /api/health）再停旧；
#    复验失败 → 回滚 upstream 到旧端口 + reload + down idle + abort（旧色一直在服务，零中断）。
#  - 停旧色**按 compose project / legacy 容器名**，不靠 `docker ps --filter publish`（其按端口匹配
#    的语义随 docker 版本而变，押注它做"停哪个容器"的安全决策不可靠）。
#
# ── 首次 BOOTSTRAP（人工一次性，迁移前做）──────────────────────────────────
#  1) 装 00-twosomeone-upstream.conf，内容 `server 127.0.0.1:3000;`（指向现存 legacy 容器）。
#  2) 把 2some.ren.conf 与 api.2some.ren.conf 的 `proxy_pass http://127.0.0.1:3000`（含带路径的）
#     改成 `proxy_pass http://twosomeone_web_active`（保留各自 URI 后缀）。
#  3) `nginx -t && nginx -s reload`。此刻 active=3000=legacy，对外无变化。
#  4) 首次跑本脚本：active=3000 → green:3010 → 切 upstream → 停 legacy 容器。此后 blue↔green 交替。
set -euo pipefail

PROJECT_DIR=/opt/apps/twosomeone/production
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ACTIVE_CONF=/etc/nginx/sites-enabled/00-twosomeone-upstream.conf
LEGACY_NAME=twosomeone-web-production
BLUE_PORT=3000
GREEN_PORT=3010
# 探 /api/healthz（轻量 liveness，与 web 镜像 docker HEALTHCHECK 同端点，~4ms 返回 200）。
# 切忌用 /api/health：那是聚合 readiness，串 stripe/openai/posthog/resend 等海外依赖，
# 国内稳定 timeout 5s+ 返回 207，必然超过下面的探测窗口，导致 idle 色健康检查假性失败、部署 abort。
HEALTH_PATH=/api/healthz
HEALTH_RETRIES=30
HEALTH_INTERVAL=2
OBSERVE_SECONDS=10
VHOSTS=(/etc/nginx/sites-enabled/2some.ren.conf /etc/nginx/sites-enabled/api.2some.ren.conf)
PUBLIC_HOSTS=(2some.ren api.2some.ren)

# ── 部署锁（flock）：非阻塞，拿不到锁说明已有部署在跑，直接退出 ──────────────────
LOCK_FILE=/run/twosomeone-bluegreen.lock
# 注意：2>/dev/null 必须限定在 { } 组内——裸 `exec ... 2>/dev/null` 会把整个脚本的 stderr 永久吞掉。
{ exec 9>"$LOCK_FILE"; } 2>/dev/null || exec 9>/tmp/twosomeone-bluegreen.lock
if ! flock -n 9; then
  echo "ERROR: another twosomeone blue-green deploy is in progress (lock held); aborting." >&2
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

# 经 nginx 端到端探（带 SNI/Host，校验 TLS + 路由 + 后端）。
probe_via_nginx() {
  local host="$1"
  curl -fsS --max-time 8 --resolve "${host}:443:127.0.0.1" "https://${host}${HEALTH_PATH}" >/dev/null 2>&1
}

cd "$PROJECT_DIR"

# ── PREFLIGHT：两个 vhost 必须已 bootstrap 到 upstream，且无残留直连旧端口 ─────────
for vh in "${VHOSTS[@]}"; do
  if [ ! -f "$vh" ]; then
    echo "ERROR: vhost $vh missing; bootstrap nginx first (see header)." >&2; exit 1
  fi
  if ! grep -qE 'proxy_pass[[:space:]]+http://twosomeone_web_active' "$vh"; then
    echo "ERROR: $vh does not reference twosomeone_web_active; bootstrap incomplete." >&2; exit 1
  fi
  if grep -qE 'proxy_pass[[:space:]]+http://127\.0\.0\.1:(3000|3010)' "$vh"; then
    echo "ERROR: $vh still has a direct 127.0.0.1:3000/3010 proxy_pass; bootstrap incomplete." >&2; exit 1
  fi
done

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
echo "==> active=${current_port} → deploying idle=${idle_color}:${idle_port}"

# 2. 起 idle 色（active 色不受影响）。COLOR/WEB_PORT 经 shell 覆盖 .env 做 compose 变量替换；
#    IMAGE_TAG 仍由 .env 提供，--pull always 拉最新构建。
COLOR="$idle_color" WEB_PORT="$idle_port" \
  docker compose -p "twosomeone-${idle_color}" -f "$COMPOSE_FILE" up -d --pull always

# 3. 探 idle 后端健康
ok=0
for _ in $(seq 1 "$HEALTH_RETRIES"); do
  if probe "http://127.0.0.1:${idle_port}${HEALTH_PATH}"; then ok=1; break; fi
  sleep "$HEALTH_INTERVAL"
done
if [ "$ok" != 1 ]; then
  echo "ERROR: idle ${idle_color}:${idle_port} failed health check; aborting (active untouched)." >&2
  docker compose -p "twosomeone-${idle_color}" -f "$COMPOSE_FILE" down || true
  exit 1
fi
echo "==> idle ${idle_color}:${idle_port} healthy"

# 4. 原子切 nginx upstream
backup="$(mktemp)"
cp -a "$ACTIVE_CONF" "$backup"
revert_conf_reload() { cp -a "$backup" "$ACTIVE_CONF"; nginx -s reload 2>/dev/null || true; }
down_idle() { docker compose -p "twosomeone-${idle_color}" -f "$COMPOSE_FILE" down || true; }
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

# 5. 切完端到端复验（经 nginx 探主站 + API 子域）；失败则回滚到旧端口、保留旧色、abort
sleep "$OBSERVE_SECONDS"
verify_ok=1
if ! probe "http://127.0.0.1:${idle_port}${HEALTH_PATH}"; then
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
    # 回滚 reload 成功 → nginx 现指 current_port（旧色一直在跑，未停），停掉刚起的 idle 才安全。
    down_idle; exit 1
  fi
  # 回滚 reload 失败 → nginx 可能仍在服务 idle_port，绝不能停 idle（否则 5xx）。保留 idle 并告警。
  echo "CRITICAL: rollback reload failed; upstream file set to ${current_port} but nginx not reloaded. Leaving idle ${idle_color}:${idle_port} UP to avoid outage. Manual: fix nginx config, then 'nginx -s reload'." >&2
  exit 1
fi
rm -f "$backup"
echo "==> verified: 2some.ren + api.2some.ren healthy via nginx on ${idle_color}:${idle_port}"

# 6. 停旧色（按 compose project；首迁额外停 legacy 单容器）。均保留容器供回滚。
echo "==> stopping previous color project twosomeone-${old_color} (if any)"
docker compose -p "twosomeone-${old_color}" -f "$COMPOSE_FILE" stop 2>/dev/null || true
if [ "$(docker inspect -f '{{.State.Running}}' "$LEGACY_NAME" 2>/dev/null || echo false)" = "true" ]; then
  echo "==> stopping legacy container ${LEGACY_NAME} (first migration)"
  docker stop "$LEGACY_NAME" >/dev/null 2>&1 || true
fi

# 7. 与 legacy deploy.sh 一致：跑可执行的 post-deploy scripts/*（当前 twosomeone 无，留作未来）
if [ -d "$PROJECT_DIR/scripts" ]; then
  echo "==> Running post-deploy scripts..."
  for script in "$PROJECT_DIR"/scripts/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      echo "--> $(basename "$script")"; "$script"
    fi
  done
fi

# 8. 清理悬空镜像（与 legacy 行为一致）
docker image prune -f >/dev/null 2>&1 || true

echo "==> deploy complete: active=${idle_color}:${idle_port}; old (:${current_port}) stopped (kept for rollback)"
echo "    rollback: docker (compose) start 旧色/${LEGACY_NAME} → 探 :${current_port} 健康 → sed upstream 端口改回 ${current_port} → nginx -t && nginx -s reload"
