# LEAPERone Email Worker（香港）

本目录部署 LEAPERone monorepo 的独立应用 `apps/email-worker`，用于接收发往
`@2some.one` 的 SMTP 邮件并提交给 2someone。生产目标固定为：

```text
主机：8.217.72.118
目录：/home/leaperone/services/leaperone-email-worker
容器：leaperone-email-worker-production
端口：主机 25/tcp -> 容器 2525/tcp
```

该应用有独立 Dockerfile、默认启动命令和依赖图，不复用 LEAPERone API 镜像，
不会运行 API、数据库迁移或其他 Worker，也不依赖德国 LEAPERone compose/数据库。

## 发布与镜像契约

生产源码必须使用 `email-worker-vX.Y.Z` tag，且 `X.Y.Z` 必须精确等于
`apps/email-worker/deno.json` 的 `version`；tag 指向的 commit 还必须已经合并进
LEAPERone `main`。Release workflow 使用与镜像一致的 Deno 2.3.3 运行该应用的
`deno task check` 和 `deno task test`，然后只构建 `apps/email-worker/Dockerfile`，
并向香港 ACR 推送同一 manifest 的三个标签：

```text
registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:email-worker-<40位源码SHA>
registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:email-worker-vX.Y.Z
registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:email-worker-latest
```

版本和 latest 标签仅用于发现；生产 Compose 只接受
`email-worker-<完整源码 SHA>@sha256:<manifest digest>`。因此重新指向 latest 或
版本标签不会隐式改变线上容器。

## GitHub Actions

工作流：[deploy-leaperone-email-worker.yml](../../.github/workflows/deploy-leaperone-email-worker.yml)。
它支持：

- `workflow_dispatch`：`ref` 必须填写精确的 `email-worker-vX.Y.Z`；
- `repository_dispatch`：事件类型为 `deploy-leaperone-email-worker`，payload 的
  `ref` 同样必须是精确版本 tag，可选 `source_sha` 必须与 tag 指向一致。

工作流使用全局生产并发锁，不取消正在进行的发布；只同步本目录到香港目标目录，
且只接受从 `leaperone-releases/main` 触发并 pin 触发时的 `${{ github.sha }}` 快照，
不会调用德国或 PVE deployer。候选容器必须通过 SMTP `220` banner healthcheck、
RepoDigest 和部署标签验证。失败时 `deploy.sh` 恢复旧 `.env` 并重建前一镜像；
首次部署尚无旧镜像时，会移除失败的新容器。

## 主机前置条件

- `2some.one` MX 指向香港主机公网 IP `8.217.72.118`。
- 云防火墙和主机防火墙允许公网入站 TCP/25。
- Postfix、Exim 或其他 SMTP 服务不得占用主机 TCP/25。
- `leaperone` 用户可使用 Docker、`flock`，并已登录香港 ACR。
- 首次自动发布前手工创建目标目录及 `.env`、`.env.worker`；工作流永远不会
  创建、传输或覆盖运行时秘密。
- 部署串行锁位于目标目录的 `.deploy.lock`，不要求发布账号写入 `/run/lock`。

## 服务器本地配置

`.env` 只含非秘密部署状态，权限必须为 `0600` 或 `0400`。首次部署时 image
字段可以暂缺，workflow 会按已发布 manifest 原子写入：

```dotenv
DEPLOY_ENV=production
REGISTRY_HOST=registry.cn-hongkong.aliyuncs.com
EMAIL_WORKER_IMAGE_TAG=email-worker-<40位源码SHA>
EMAIL_WORKER_IMAGE_DIGEST=sha256:<64位digest>
EMAIL_WORKER_SOURCE_SHA=<40位源码SHA>
EMAIL_WORKER_RELEASE_TAG=email-worker-vX.Y.Z
RELEASES_SHA=<40位leaperone-releases源码SHA>
```

`.env.worker` 是唯一的运行时环境来源，权限同样为 `0600` 或 `0400`：

```dotenv
EMAIL_WORKER_ENVIRONMENT=production
EMAIL_LISTENER_HOSTNAME=0.0.0.0
EMAIL_LISTENER_PORT=2525
EMAIL_MAX_MESSAGE_BYTES=33554432
EMAIL_IDLE_TIMEOUT_MS=60000
EMAIL_SESSION_TIMEOUT_MS=300000
EMAIL_MAX_CONNECTIONS=8
EMAIL_MAX_COMMAND_BYTES=8192
EMAIL_MAX_RECIPIENTS=16
TWOSOMEONE_BASE_URL=https://<2someone 后端域名>
TWOSOMEONE_INTERNAL_SECRET=<与 2someone 后端一致的内部密钥>
SENTRY_DSN_EMAIL_WORKER=<可选>
SENTRY_TRACES_SAMPLE_RATE_EMAIL_WORKER=0.1
```

禁止加入 `DATABASE_URL` 或 API 遗留的 `DENO_ENV`、`EMAIL_LOG_ENABLED`、
`POSTHOG_PROJECT_TOKEN`、`SENTRY_DSN_API`。本目录 `.gitignore` 忽略所有本地 env
和临时回退文件。

## 首次准备与验证

```bash
install -d -m 700 /home/leaperone/services/leaperone-email-worker
cd /home/leaperone/services/leaperone-email-worker
chmod 700 preflight.sh deploy.sh
chmod 600 .env .env.worker
```

镜像字段由首次 workflow 发布写入后，可执行：

```bash
./preflight.sh
docker compose ps
docker inspect --format '{{.State.Health.Status}}' leaperone-email-worker-production
docker compose logs --tail 100 email-worker
netstat -ltn | grep -E '(^|[.:])25[[:space:]]'
```

随后必须从另一台公网主机确认 `8.217.72.118:25` 返回 `220` SMTP banner，覆盖
云防火墙和运营商链路。Docker 日志按单文件 10 MiB、3 个文件轮转。

## 手工回退

正常发布失败会自动回退。手工回退时，从受保护的发布记录中取前一版本的完整
source SHA、manifest digest、release tag 和 releases SHA，再调用：

```bash
cd /home/leaperone/services/leaperone-email-worker
./deploy.sh <source-sha> <sha256:digest> <email-worker-vX.Y.Z> <releases-sha>
```

不要部署 `email-worker-latest` 或仅版本标签，不要使用 `--build`，也不要在香港
主机修改源码。
