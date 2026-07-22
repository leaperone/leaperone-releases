# LEAPERone Email Worker（香港）

本目录用于把 2someone 邮箱投稿接收器作为独立 Docker Compose 项目部署到
香港主机 `8.217.72.118`。生产目录固定为：

```text
/home/leaperone/services/leaperone-emailer
```

它复用 LEAPERone 的不可变 `api-<完整源码 SHA>` 镜像，但通过独立 entrypoint
只执行 `apps/api/emailer.ts`。它不会执行 `apps/api/main.ts`，因此不会启动
LEAPERone HTTP API、数据库迁移、图片 Worker、视频 Worker 或临时图片服务，
也不依赖德国服务器上的 `compose/leaperone` 项目或数据库。

## 主机前置条件

- `2some.one` 的 MX 最终指向香港主机公网 IP `8.217.72.118`。
- 云防火墙和主机防火墙允许公网入站 TCP/25。
- Postfix、Exim 或其他 SMTP 服务不得占用主机 TCP/25。`preflight.sh` 会在首次
  启动前 fail closed；更新正在运行的本服务时则允许它继续占用该端口。
- `leaperone` 用户可以使用 Docker，并已登录
  `registry.cn-hongkong.aliyuncs.com`。Registry 凭据不得写入本目录的 env 文件。

## 仅保存在服务器上的配置

`.env` 只供 Docker Compose 插值，权限必须为 `0600` 或 `0400`：

```dotenv
DEPLOY_ENV=production
REGISTRY_HOST=registry.cn-hongkong.aliyuncs.com
API_IMAGE_TAG=api-<40 位小写 LEAPERone 源码 SHA>
```

`.env.worker` 是容器唯一的运行时环境来源，权限同样必须为 `0600` 或 `0400`：

```dotenv
DENO_ENV=production
EMAIL_LISTENER_HOSTNAME=0.0.0.0
EMAIL_LISTENER_PORT=25
EMAIL_MAX_MESSAGE_BYTES=33554432
EMAIL_IDLE_TIMEOUT_MS=60000
EMAIL_SESSION_TIMEOUT_MS=300000
EMAIL_MAX_CONNECTIONS=8
EMAIL_MAX_COMMAND_BYTES=8192
EMAIL_MAX_RECIPIENTS=16
EMAIL_LOG_ENABLED=false
TWOSOMEONE_BASE_URL=https://<2someone 后端域名>
TWOSOMEONE_INTERNAL_SECRET=<与 2someone 后端一致的非默认内部密钥>
SENTRY_DSN_API=<可选>
SENTRY_TRACES_SAMPLE_RATE=0.1
POSTHOG_PROJECT_TOKEN=<可选>
```

不要在 `.env.worker` 中加入 `DATABASE_URL`；香港独立 Worker 关闭数据库邮件日志，
避免重新耦合 LEAPERone 生产数据库。不要提交这两个文件；本目录的 `.gitignore`
已明确忽略它们。不要把 Registry、Sentry、PostHog 或内部投稿密钥写入 compose、
README 或部署脚本。

## 首次部署

将本目录中的受版本控制文件同步到固定生产目录，再在香港主机执行：

```bash
cd /home/leaperone/services/leaperone-emailer
chmod 700 preflight.sh
chmod 600 .env .env.worker
./preflight.sh
docker compose pull
docker compose up -d
docker compose ps
```

不要使用 `--build`：这个项目只消费 LEAPERone API workflow 已发布到香港 ACR
的镜像。Compose 发布主机 `25:25/tcp`，健康检查从容器内连接 SMTP 监听端口并
要求服务返回 `220` banner；容器使用 `unless-stopped` 自动重启，并限制为
1 CPU、1 GiB 内存和 128 个进程。

## 验证与运维

```bash
cd /home/leaperone/services/leaperone-emailer
docker compose ps
docker inspect --format '{{.State.Health.Status}}' leaperone-emailer-production
docker compose logs --tail 100 emailer
netstat -ltn | grep -E '(^|[.:])25[[:space:]]'
```

`docker compose ps` 必须显示 `healthy`，宿主机必须显示 `0.0.0.0:25` 或等价的
双栈监听。之后应从另一台公网主机验证 `8.217.72.118:25` 能收到 `220` SMTP
banner；不要只在香港主机本地验证，因为本地测试无法覆盖云防火墙和运营商封锁。

日志采用 Docker `json-file` 轮转（单文件 10 MiB，保留 3 个）。常用操作：

```bash
docker compose restart emailer
docker compose logs -f --tail 100 emailer
docker compose stop emailer
```

## 升级与回退

该服务不会随德国 LEAPERone API compose 自动更新。升级时，把 `.env` 的
`API_IMAGE_TAG` 改为已由 LEAPERone API workflow 发布的另一个完整 SHA 标签，
记录当前标签后执行：

```bash
./preflight.sh
docker compose pull
docker compose up -d --wait --wait-timeout 90
```

若新版本异常，把 `API_IMAGE_TAG` 恢复为刚才记录的旧标签，重复同样命令即可
回退。禁止使用 `api-latest`，避免 API 发布在未审查 Email Worker 的情况下隐式
改变香港服务。
