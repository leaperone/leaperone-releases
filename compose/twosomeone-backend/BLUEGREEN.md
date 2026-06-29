# twosomeone backend 蓝绿部署 + 跨服务色感知网格(PVE LXC 200 / production)

零停机蓝绿。CI 链路不变(打 `backend-v*` tag → repository_dispatch → `deploy-twosomeone-backend.yml`
→ `deploy-pve.yml` scp `compose/twosomeone-backend/*` 到 `/opt/apps/twosomeone-backend/production/`
+ ssh 以 root 跑 `/opt/apps/bin/deploy.sh twosomeone-backend production`)。变化只在「deploy.sh 怎么部署」。

## 工作机制

- `docker-compose.yml`:去 `container_name`,用 compose project name 区分两色
  (`twosomeone-backend-blue` / `twosomeone-backend-green`),端口 blue=3003 / green=3013
  (host → 容器 3001)。`stop_grace_period: 110s` 配合 backend ~100s 优雅停机(worker 抽干)。
- `deploy-bluegreen.sh`:随 compose 一起 scp;通用 `deploy.sh` 探测到它可执行即委派。
  流程:flock(backend 专用锁)→ preflight(backend.2some.ren.conf + 10-twosomeone-internal.conf
  均已指 `twosomeone_backend_active` 且无残留直连)→ 起空闲色 → 探 `/health` → **校验空闲色经
  `WEB_BASE_URL` 反调 web 可达**(光探 /health 漏不掉 backend→web 断裂)→ 原子切 nginx upstream
  → 切后经 nginx 复验 `backend.2some.ren/health` → 失败回滚保留旧色 → 按 compose project 停旧色
  (`-t 110` 给足优雅停机)。
- WS 长连接在停旧色时断开,客户端自动重连到新色(PG LISTEN/NOTIFY 跨实例投递,无 sticky 需求)。

## 跨服务色感知网格(关键)

web↔backend 内部调用此前绕过 nginx、写死 host 端口(`host.docker.internal:3003/3000`),蓝绿换色即断。
现统一走 nginx「活动色」upstream,自动跟随两端蓝绿:

- nginx `00-twosomeone-backend-upstream.conf`:`upstream twosomeone_backend_active { server 127.0.0.1:3003; }`
  (deploy-bluegreen.sh 切 3003↔3013)。
- nginx `10-twosomeone-internal.conf`:两个 plain-HTTP 内部监听,ACL 只放行 docker 网桥
  (`allow 172.16.0.0/12; deny all`)+ 只放行 `/api/internal/`(其余 444)+ `client_max_body_size 25m`:
  - `:3030` → `twosomeone_backend_active`(web→backend,web `.env` `BACKEND_BASE_URL=http://host.docker.internal:3030`)
  - `:3031` → `twosomeone_web_active`(backend→web,backend `.env` `WEB_BASE_URL=http://host.docker.internal:3031`)
- `backend.2some.ren.conf`:`proxy_pass http://twosomeone_backend_active`(公网 WS/REST)。

## 一次性 BOOTSTRAP(人工,在 LXC 200 上,迁移前做一次)

非破坏性,完成后 active 仍指现存 legacy 容器(:3003),对外零变化。

1. 装 `00-twosomeone-backend-upstream.conf`(server 127.0.0.1:3003)+ `10-twosomeone-internal.conf`。
2. `backend.2some.ren.conf`:`proxy_pass http://127.0.0.1:3003` → `http://twosomeone_backend_active`。
3. host `.env`:web `BACKEND_BASE_URL` → `http://host.docker.internal:3030`;backend `WEB_BASE_URL`
   → `http://host.docker.internal:3031`。
4. `nginx -t && nginx -s reload`。
5. 应用 .env:web 蓝绿切流一次(应用 BACKEND_BASE_URL)→ 首次 backend 蓝绿切流
   (`deploy.sh twosomeone-backend production`,legacy:3003 → green:3013,应用 WEB_BASE_URL,切 upstream,停 legacy)。
   此后 blue(3003) ↔ green(3013) 稳态交替。

## 回滚

先 `docker compose -p twosomeone-backend-<旧色> start`(首迁:`docker start twosomeone-backend-production`)→
探 `:<旧端口>/health` → sed `00-twosomeone-backend-upstream.conf` 端口改回 → `nginx -t && nginx -s reload`。
旧色停止后保留未删。脚本切后复验失败会自动回滚。

## 注意

- 仅 PVE production 走蓝绿。
- env 单一来源 = host `.env`(envx 不参与部署,见 2SOMEone PR #857)。
- 内部监听仅内网 + ACL + Bearer,不公网暴露;mobile polling 无需 sticky(蓝绿稳态单色)。
- 不可变 sha digest 仍待办。
