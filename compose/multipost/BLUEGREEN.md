# multipost web 蓝绿 + L4 透传架构（PVE LXC200 / production）

2026-06-30 起：HK 对 multipost 改为纯 L4 端口透传，TLS 终止挪到源站，源站做 nginx upstream 蓝绿。

## 架构

```
multipost.app / api.multipost.app
  → CF → HK:443 stream(ssl_preread, L4 透传, 不终止 TLS)
  → map $ssl_preread_server_name → upstream multipost_origin(127.0.0.1:19900 = HK frps)
  → frp 隧道 → LXC200 frpc(localPort 9443)
  → 源站 nginx multipost-local.conf(listen 127.0.0.1:9443 ssl proxy_protocol, 终止 TLS)
       multipost.app      → proxy_pass multipost_web_active        (容器 /)
       api.multipost.app  → proxy_pass multipost_web_active/api/   (容器 /api/ 重写)
  → web 容器  blue:9900 / green:9910
```

TLS 在源站终止（wildcard 证书 acme.sh + Cloudflare，自动续期）；HK 纯 L4、不持 multipost 证书；
真实 client IP 经 HK stream `proxy_protocol on` → 源站 `listen ... proxy_protocol` 解析；
蓝绿只切 `multipost_web_active` 的 upstream 端口。

## 组件落点

- 证书：`/etc/nginx/ssl/multipost.app/{fullchain.cer,multipost.app.key}`（acme ECC wildcard，reloadcmd 自动部署）。
- 源站 nginx：`/etc/nginx/sites-enabled/multipost-local.conf`（源在本仓库 `nginx/multipost-local.conf`）。
- frpc：LXC200 `/opt/apps/frpc/conf.d/multipost.toml`，`multipost-web` `localPort=9443 remotePort=19900`（容器名 `frpc`，无 admin API，改配置需 `docker restart frpc`）。
- HK：`/usr/local/nginx/conf/nginx.conf` 的 `stream{}` —— `upstream multipost_origin { server 127.0.0.1:19900; }` + map 把 `multipost.app`/`api.multipost.app` 指向它（`md.multipost.app` 仍走旧 7443）。
- 蓝绿：`docker-compose.web.yml`（web，COLOR/WEB_PORT 区分两色）+ `deploy-bluegreen.sh`（切 upstream）；`docker-compose.yml` 常驻 video-stt-worker + backend（`--profile backend`，PVE 单例）。

## 蓝绿机制

通用 `deploy.sh` 探测到可执行 `deploy-bluegreen.sh` → 委派。起 idle 色(9910) → 探 `/api/health`(纯
liveness) → 备份并 sed 改 `multipost-local.conf` 的 upstream 端口 → `nginx -t` → `nginx -s reload`
→ 经源站 9443(proxy_protocol+TLS) 端到端复验 → 按 project 停旧色 → 更新常驻 worker/backend → prune。

**前置**：`:latest` 镜像须含 `/api/health`（一次 web 构建后满足）。

## 回滚

- 蓝绿层：脚本切后复验失败自动回滚 upstream；人工 = start 旧色容器 → 探 `/api/health` → sed upstream
  端口改回 → `nginx -t && nginx -s reload`。
- 架构层（回退到 HK 终止 TLS 的旧链路）：
  - HK：`sudo cp /tmp/nginx.conf.orig-bak /usr/local/nginx/conf/nginx.conf && sudo nginx -s reload`
  - frpc：`cp multipost.toml.bak-l4 multipost.toml && docker restart frpc`（localPort 回 9900）
