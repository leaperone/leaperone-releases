# multipost web 蓝绿部署（PVE LXC 200 / production）

零停机蓝绿。CI 链路不变（push `web-v*` tag → repository_dispatch → deploy-multipost.yml →
deploy-pve.yml scp `compose/multipost/*` 到 `/opt/apps/multipost/production/` + ssh 以 root 跑
`/opt/apps/bin/deploy.sh multipost production`）。变化只在「deploy.sh 怎么部署」这一层。

范围：**只对 web 做蓝绿**。video-stt-worker 是无端口单例后台 worker，由主 `docker-compose.yml`
常驻、每次部署 recreate（瞬断可接受）。backend 不参与蓝绿（本机 PVE profile 默认禁用；启用前须确保
全局只有一个实例轮询 multipost_db cron）。

## 工作机制

- `docker-compose.web.yml`：只含 web，去掉写死的 `container_name`，用 compose project name 区分两色
  （`multipost-web-blue` / `multipost-web-green`），端口 blue=9900 / green=9910。
- `docker-compose.yml`：剥离 web 后只剩 video-stt-worker（+ 默认禁用的 backend 占位），project 仍为
  `multipost-production`，worker 容器名不变。
- `deploy-bluegreen.sh`：随 compose 一起 scp 到 production 目录。通用 `deploy.sh` 探测到它可执行就
  `exec` 委派（其它项目无此文件 → 保持 legacy 停机式 `down`→`up`，行为不变）。
- 切流：起空闲色 → `/api/health` 探测 → 备份并 sed 改写 nginx upstream 端口 → `nginx -t` →
  `nginx -s reload`（任一步失败回滚 conf 并 reload、down 掉空闲色）→ 观察 10s → 经 nginx 端到端复验 →
  按 project 停旧色 → 更新常驻 worker → prune。
- nginx 侧只有 `00-multipost-upstream.conf` 一个文件被切换；`multipost.app` vhost
  `proxy_pass http://multipost_web_active`。

## ⚠ 落地前需在 PVE LXC 200 上核实的参数

1. **green 端口 9910 是否空闲**：`ss -ltnp | grep 9910`（应无输出）。被占则改 `GREEN_PORT`。
2. **vhost 文件名 + 是否有其它子域反代到 web**：`grep -rl '127.0.0.1:9900' /etc/nginx/sites-enabled/`。
   若不止 `multipost.app.conf`，把所有相关文件都加进脚本的 `VHOSTS=()` 并在 bootstrap 时一并改。
3. **worker 归属 project**：`docker inspect multipost-video-stt-worker-production -f '{{index .Config.Labels "com.docker.compose.project"}}'`
   应为 `multipost-production`，否则 `up -d` 会另起一份。
4. **multipost.app 的 TLS 在哪终止**：脚本 `probe_via_nginx` 假设 PVE 本机在 `:443` 终止 TLS。按部署
   拓扑，HK 是 frp 入口跳板，TLS 很可能在 HK 终止——若如此，请把 `probe_via_nginx` 改为探 PVE 本地
   vhost 的实际 listen 端口（带 `Host: multipost.app` 头）。
<!-- PART1_END -->
