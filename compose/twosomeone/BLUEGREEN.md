# twosomeone web 蓝绿部署（PVE LXC 200 / production）

零停机蓝绿。CI 链路不变（push `web-v*` tag → repository_dispatch → deploy-twosomeone.yml →
deploy-pve.yml scp `compose/twosomeone/*` 到 `/opt/apps/twosomeone/production/` + ssh 以 root 跑
`/opt/apps/bin/deploy.sh twosomeone production`）。变化只在「deploy.sh 怎么部署」这一层。

## 工作机制

- `docker-compose.yml`：去掉写死的 `container_name`，用 compose project name 区分两色
  （`twosomeone-blue` / `twosomeone-green`），端口 blue=3000 / green=3010。
- `deploy-bluegreen.sh`：随 compose 一起 scp 到 production 目录。通用 `deploy.sh` 探测到它可执行就
  `exec` 委派（其它项目无此文件 → 保持 legacy 停机式 `down`→`up`，行为不变）。
- 切流：起空闲色 → `/api/health` 探测（curl -f：503 失败 / 207·200 通过）→ 备份并 sed 改写
  nginx upstream 端口 → `nginx -t` → `nginx -s reload`（任一步失败回滚 conf 并 reload、down 掉空闲色）
  → 观察 10s → 按端口停旧色 → prune。
- nginx 侧只有 `00-twosomeone-upstream.conf` 一个文件被切换；`2some.ren` 与 `api.2some.ren` 两个 vhost
  都 `proxy_pass http://twosomeone_web_active`，一次切换同时覆盖主站与 API 子域。

## 一次性 BOOTSTRAP（人工，在 LXC 200 上，迁移前做一次）

非破坏性：完成后 active 仍指向现存 legacy 容器（:3000），对外零变化。

1. 安装上游文件 `/etc/nginx/sites-enabled/00-twosomeone-upstream.conf`：

   ```nginx
   upstream twosomeone_web_active {
       server 127.0.0.1:3000;   # ACTIVE — deploy-bluegreen.sh 在此切换 3000 <-> 3010
   }
   ```

2. 把两个 vhost 的后端指向上游（先备份到 sites-enabled 之外的目录）：
   - `2some.ren.conf`：`proxy_pass http://127.0.0.1:3000;` → `proxy_pass http://twosomeone_web_active;`
   - `api.2some.ren.conf`：全部 `http://127.0.0.1:3000`（含 6 条带 `/api/collect/...` 路径重写的 + 1 条
     catch-all）→ `http://twosomeone_web_active`，**保留各自 URI 后缀**。

3. `nginx -t && nginx -s reload`。此刻 active=3000=legacy。

4. 首次部署：`/opt/apps/bin/deploy.sh twosomeone production` → 起 green:3010 → 切 upstream →
   停 :3000 legacy 容器。此后 blue(3000) ↔ green(3010) 稳态交替。

## 回滚

**顺序很重要**（先把旧后端拉起来再把流量切回去，否则会短暂指向已停后端）：

1. 启动旧色容器：`docker compose -p twosomeone-<旧色> start`（首迁回滚 legacy：`docker start twosomeone-web-production`）。
2. 探旧色健康：`curl -fsS http://127.0.0.1:<旧端口>/api/health`。
3. 把 `00-twosomeone-upstream.conf` 端口 sed 回旧端口 → `nginx -t && nginx -s reload`。

（旧色停止后保留未删，正是为此。脚本在切流后复验失败时会自动回滚，无需人工介入；上述为人工兜底。）

## 注意

- 仅 PVE production 走蓝绿。PVE beta（:3001）不经 deploy-pve.yml，其 production 目录之外的 compose 不受影响。
- 镜像沿用 `.env` 的 `IMAGE_TAG=web-main-latest` + `--pull always`，语义与 legacy 一致。
- DB migration 在两色同连一库下必须向后兼容（expand/contract）；这是 build-and-push 阶段 atlas
  migrate + drift-check 的既有约束，蓝绿下尤其要守。
