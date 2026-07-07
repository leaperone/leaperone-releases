# multipost web 蓝绿部署（Germany / production）

迁移到德国源站后，MultiPost 不再经过 HK stream / FRP。流量路径：

```text
multipost.app / api.multipost.app
  -> Cloudflare
  -> Germany Nginx :443
  -> multipost_web_active upstream
  -> web 容器 blue:9900 / green:9910
```

TLS 在德国源站终止，证书由 acme.sh + Cloudflare DNS-01 签发并自动续期。Nginx 通过
`/etc/nginx/snippets/cloudflare-real-ip.conf` 从 `CF-Connecting-IP` 还原真实客户端 IP。

## 组件落点

- 证书：`/etc/nginx/ssl/multipost.app/{fullchain.cer,multipost.app.key}`。
- Nginx：`/etc/nginx/sites-enabled/multipost-local.conf`，源文件在本仓库 `nginx/multipost-local.conf`。
- web 蓝绿：`docker-compose.web.yml`，`COLOR` / `WEB_PORT` 区分两色。
- 常驻服务：`docker-compose.yml` 管理 `video-stt-worker` 和 `backend`。
- 共享 Docker 网络：`leaperone-prod`，Postgres 和业务容器都加入此网络。

## 路由

- `multipost.app/*` -> web 容器原路径。
- `api.multipost.app/*` -> web 容器 `/api/*`。例如 `api.multipost.app/foo` 会代理到容器 `/api/foo`。

## 蓝绿机制

通用 `/opt/apps/bin/deploy.sh` 探测到可执行 `deploy-bluegreen.sh` 后委派执行：

1. 解析当前 active 端口，必须是 `9900` 或 `9910`。
2. 拉起 idle 色 web 容器。
3. 探测 idle 色 `/api/health`。
4. 备份并替换 Nginx upstream 端口。
5. `nginx -t && nginx -s reload`。
6. 通过本机 `https://multipost.app` 和 `https://api.multipost.app` 端到端复验。
7. 停旧色容器。
8. 按 `DEPLOY_COMPONENTS` 更新常驻 `video-stt-worker` / `backend`；未设置时保持旧行为，视为 `all`。

## 回滚

蓝绿层脚本在复验失败时会自动回滚 upstream。人工回滚：

1. 启动旧色容器。
2. 探测旧色端口 `/api/health`。
3. 把 `multipost-local.conf` 的 `multipost_web_active` 端口改回旧色。
4. 执行 `nginx -t && nginx -s reload`。

DNS 已经切到德国且德国库开始接写入后，不应直接切回旧 PVE/HK 链路，否则会产生数据分叉。
