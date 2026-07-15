# NIMEI 德国生产部署

NIMEI 与 DokiLove 共用德国服务器和 `dokilove_db`，但使用独立目录、容器和入口：

- 目录：`/opt/apps/nimei/production`
- 蓝绿端口：`127.0.0.1:9811` / `127.0.0.1:9812`
- Nginx：`/etc/nginx/sites-enabled/nimei-local.conf`
- 域名：`nimei.app` / `www.nimei.app`
- 构建标签：`registry.cn-hongkong.aliyuncs.com/leaperone/nimei:web-<full-sha>`
- 实际部署：`registry.cn-hongkong.aliyuncs.com/leaperone/nimei@sha256:<manifest-digest>`

部署只把 `/api/ready` 当作就绪信号。这个端点必须连接 PostgreSQL 并验证
NIMEI 身份、聊天和私有角色所需 schema；纯 `/api/health` 不能用于切流。

## 首次 bootstrap

1. 创建 `/opt/apps/nimei/production/.env`，至少配置数据库、独立 NIMEI
   `AUTH_SECRET` / `BETTER_AUTH_SECRET`、`BETTER_AUTH_URL=https://nimei.app`、
   `TRUSTED_ORIGINS=https://nimei.app,https://www.nimei.app`、Resend、现有 DokiLove
   `ENCRYPTION_KEY`，以及 DokiLove 热 OSS 的 `OSS_*` / 兼容 `JP_OSS_*` 变量。
   `ENCRYPTION_KEY` 必须复用，否则迁移后的 BYOK ciphertext 无法解密；NIMEI auth secret
   则必须独立，不能和 DokiLove 共用。
   `.env` mode 必须为 `400` 或 `600`，并配置 `TRUSTED_PROXY=1`；数据库、
   `ENCRYPTION_KEY`、热 OSS 与 Sentry 必须通过哈希比对匹配 DokiLove。
2. 用 acme.sh + Cloudflare DNS-01 签发
   `/etc/nginx/ssl/nimei.app/{fullchain.cer,nimei.app.key}`。
3. 同步本目录后执行
   `/opt/apps/nimei/production/install-nginx.sh`。安装器只允许首次创建配置，拒绝覆盖 active upstream。
4. 先 dispatch `components=nimei` 或 `components=all`。首次流程会先切 DokiLove
   consumer-lockout 镜像、验证注册/改密/passkey 注册均为 403、备份数据库，再运行
   migration 0027，最后启动 NIMEI。
5. NIMEI ready 后再把 Cloudflare `nimei.app` / `www` 指到德国源站。

旧 DokiLove passkey 不复制到 `nimei_passkey`：WebAuthn 凭据绑定 `doki.love` RP ID，
在 `nimei.app` 无法使用。旧表保留审计数据；用户用已迁移的密码登录 NIMEI 后重新注册 passkey。

## 监控复用

- PostHog 使用 DokiLove project `419311`，构建 secret 为
  `DOKILOVE_POSTHOG_PROJECT_KEY`，host 复用 DokiLove 反代 `https://t.doki.love`；
  事件用 `app=nimei-web` / `app=dokilove-web` 区分。
- Sentry 继续使用 org `leaperone`、project `dokilove-web` 和同一 DSN；release
  使用 `nimei-web@<full-sha>` 与 `dokilove-web@<full-sha>` 区分应用。

## 回滚边界

NIMEI 自身可以在 9811/9812 间回滚到 migration 0027 之后的旧色。migration 0027
完成后不得自动启动旧的 consumer-enabled DokiLove 镜像；服务器 marker 和 DokiLove
preflight 会拒绝 tag-only、未登记 SHA 或 RepoDigest 不符的镜像。若 migration 已完成但
marker 写入失败，下一次 `components=nimei/all` 会在验证 pending journal、备份、数据不变量、
当前 Doki RepoDigest 与冻结 endpoint 后补写 marker，再继续 NIMEI。数据库回滚必须从首次 cutover 前的已校验 dump
恢复，并同时协调 DokiLove/NIMEI 停写，不能只切镜像。
