# LEAPERone Germany Migration Runbook

Status: design, not executed.
Last updated: 2026-07-07.

This runbook covers the planned LEAPERone migration:

- Move `leaperone_db` from PVE LXC 210 to Germany `postgres-production`.
- Run `apps/web` on Germany.
- Run `apps/api` on Germany as primary.
- Keep Hong Kong API as standby/fallback, then promote to peer only after shared state is safe.
- Update `leaperone-releases` workflows, compose files, and GitHub Secrets.

Any step that writes production DB, stops production services, changes DNS, or changes GitHub Secrets requires explicit approval before execution.

## 1. Target State

| Component | Target | Notes |
|---|---|---|
| `leaper.one` | Germany `159.195.43.38` | Next.js `apps/web` only. |
| `api.leaper.one` | Germany `159.195.43.38` first | Later can use Cloudflare LB: DE primary, HK fallback. |
| `cn-hongkong.leaper.one` | Hong Kong `8.217.72.118` | Stable HK API fallback endpoint. |
| `leaperone_db` | Germany `postgres-production` | Same Postgres instance as `dokilove_db` and `multipost_db`. |
| HK API | Fallback/peer | Must use DE DB over WireGuard/private tunnel, not public PG. |
| PVE `leaperone_db` | Read-only snapshot after cutover | Do not write after DE receives production traffic. |

Current facts verified on 2026-07-07:

- PVE `leaperone_db`: PostgreSQL 16.13, about 20 MB, 22 tables total.
- PVE schemas: `public` and `drizzle`.
- `public`: 21 business tables.
- `drizzle.__drizzle_migrations`: migration history table.
- Germany `postgres-production`: PostgreSQL 16.14, healthy, binds host `127.0.0.1:5432`, Docker network `leaperone-prod`.
- Germany currently has `dokilove_db` and `multipost_db`; it does not yet have `leaperone_db`.

## 2. Non-Goals For First Cutover

Do not make DE and HK active-active on day one.

Known blockers:

- API RPM limiting is process-local today; multi-region active-active multiplies effective limits.
- API process currently starts HTTP server, migrations, image worker, temp-image server, and SMTP listener together.
- Image "uploading" callbacks use local `/tmp` temp files; cross-node routing can 404.
- HK-to-DE database connectivity should be private; do not expose Postgres publicly.

First cutover should be:

1. DE web + DE API primary.
2. HK API stopped or standby only.
3. HK fallback enabled only after DB connectivity and API process roles are explicit.

## 3. Required Code Changes In `leaperone/LEAPERone`

These changes should land before production cutover.

### 3.1 API runtime role flags

Add env gates in `apps/api/main.ts`:

| Env | Default | Purpose |
|---|---:|---|
| `RUN_MIGRATIONS` | `true` for one primary only | Avoid every API replica running Drizzle migrations. |
| `ENABLE_IMAGE_WORKER` | `true` on one worker node only | Avoid uncontrolled duplicate workers and temp-file routing surprises. |
| `ENABLE_EMAIL_LISTENER` | `false` by default | Port 25 cannot be bound by every API container. |
| `ENABLE_TEMP_IMAGE_SERVER` | `true` only where temp URLs route correctly | Or replace temp URLs with OSS-backed URLs. |

Recommended first production split:

- DE API primary: `RUN_MIGRATIONS=true`, `ENABLE_IMAGE_WORKER=true`, `ENABLE_EMAIL_LISTENER=true` only if SMTP is needed.
- HK API fallback: `RUN_MIGRATIONS=false`, `ENABLE_IMAGE_WORKER=false`, `ENABLE_EMAIL_LISTENER=false`.
- Extra DE API replicas: `RUN_MIGRATIONS=false`, `ENABLE_IMAGE_WORKER=false`, `ENABLE_EMAIL_LISTENER=false`.

### 3.2 Shared rate limiting

Before active-active, replace `apps/api/middleware/rateLimiter.ts` process-local `Map` with shared state:

- Preferred: Redis/Valkey in DE, HK over WireGuard.
- Acceptable short-term: Postgres advisory/UPSERT counters if traffic is modest.

Until then, treat HK as standby/failover, not weighted traffic.

### 3.3 Image temp URLs

Current temp image behavior writes to local disk and exposes `TEMP_IMAGE_BASE_URL`.

For multi-node:

- Either send `TEMP_IMAGE_BASE_URL` to a node-specific origin and keep callbacks sticky.
- Or skip local temp URLs and upload preview images to OSS immediately.
- Or run image worker only on DE primary and route `/temp-images/*` only to that node.

### 3.4 Web configuration

DE web env must include:

- `DATABASE_URL=postgresql://<app-user>:<password>@postgres:5432/leaperone_db`
- `BETTER_AUTH_URL=https://leaper.one`
- `BASE_URL=https://leaper.one`
- Same `BETTER_AUTH_SECRET` as the current production site if preserving sessions.
- OAuth provider callback URLs updated/verified for `https://leaper.one`.

`apps/web/lib/auth.ts` already trusts `https://leaper.one` in production.

## 4. Required Changes In `leaperone/leaperone-releases`

### 4.1 Add `compose/leaperone/`

Create a Germany deployment directory:

```text
compose/leaperone/
  docker-compose.yml
  nginx/
    leaper.one.conf
    api.leaper.one.conf
  scripts/
    10-install-nginx-conf.sh
```

Recommended ports, after verifying they are free on DE:

- Web: `127.0.0.1:9800 -> container 3000`
- API: `127.0.0.1:9801 -> container 9000`

Compose requirements:

- Use images:
  - `registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:web-latest`
  - `registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:api-latest`
- Attach both services to external network `leaperone-prod`.
- Use `.env` on the server; do not commit secrets.
- Use `postgres` network alias for `DATABASE_URL`.
- Set API runtime role flags explicitly.
- Set `INSTALL_NGINX_CONF=true` in the server `.env` only after TLS certs exist under `/etc/nginx/ssl/leaper.one`.

### 4.2 Update `deploy-leaperone.yml`

Current behavior:

- Builds web/api images.
- Runs migrations using `secrets.LEAPERONE_DATABASE_URL`.
- SSH deploys to Hong Kong using `ALIYUN_HK_HOST` and `DEPLOY_LEAPERONE_SCRIPT`.

Target behavior:

1. Continue checking out `leaperone/LEAPERone`.
2. Continue building and pushing `web-latest` and `api-latest`.
3. Run DB migration against DE, not PVE.
4. Deploy `compose/leaperone` to DE through the existing reusable `deploy-de.yml`.

Migration options:

- Preferred: create an SSH tunnel in GitHub Actions:

  ```bash
  ssh -fN \
    -L 15432:127.0.0.1:5432 \
    -p "$DE_APP_PORT" \
    "$DE_APP_USERNAME@$DE_APP_HOST"

  DATABASE_URL="$LEAPERONE_DE_DATABASE_URL" pnpm --filter @leaperone/db db:migrate
  ```

  In this model, `LEAPERONE_DE_DATABASE_URL` points to `127.0.0.1:15432`.

- Alternative: run migrations on the DE host using a one-off container or checked-out release. This avoids putting DB network details in Actions, but the workflow must fail if migration fails.

Do not run migrations against PVE after cutover.

### 4.3 Add HK API fallback workflow

Do not keep the current "web + api to HK" deploy as the main LEAPERone deploy.

Create either:

- `deploy-leaperone-hk-api.yml`, or
- an `env=hk-api` branch in `deploy-leaperone.yml`.

HK fallback deployment must:

- Deploy API only.
- Use DE database over WireGuard/private address.
- Set `RUN_MIGRATIONS=false`.
- Set `ENABLE_IMAGE_WORKER=false`.
- Set `ENABLE_EMAIL_LISTENER=false`.
- Not deploy web.

### 4.4 Add LEAPERone-specific migration scripts

Do not reuse the existing DokiLove/MultiPost scripts directly; they are hard-coded for those databases.

Add scripts under:

```text
ops/leaperone-de-migration/
  preflight.sh
  dump-and-copy-leaperone-db.sh
  restore-leaperone-db-on-de.sh
  verify-leaperone-db.sh
  cutover-dns-to-de.sh
  rollback-dns-to-hk.sh
```

Important differences from DokiLove/MultiPost:

- Stop write-side LEAPERone services on HK, not PVE app containers.
- Dump PVE LXC 210 `leaperone_db`.
- Include `drizzle.__drizzle_migrations`.
- Restore into a new Germany `leaperone_db`.
- Create a least-privilege app DB role; do not run apps as `postgres`.

## 5. GitHub Secrets And Variables

Repository: `leaperone/leaperone-releases`.

Existing secrets verified by name:

- `DE_APP_HOST`
- `DE_APP_USERNAME`
- `DE_APP_PORT`
- `DE_APP_SSH_KEY`
- `ALIYUN_DOCKER_USERNAME`
- `ALIYUN_DOCKER_PASSWORD`
- `SENTRY_AUTH_TOKEN`
- `LEAPERONE_DATABASE_URL`
- `ALIYUN_HK_HOST`
- `ALIYUN_CN_USERNAME`
- `ALIYUN_CN_PORT`
- `ALIYUN_CN_SSH_PRIVATE_KEY`
- `DEPLOY_LEAPERONE_SCRIPT`

Required changes:

| Name | Action | Purpose |
|---|---|---|
| `LEAPERONE_DE_DATABASE_URL` | Add after DE DB exists | CI migration URL for DE. If using SSH tunnel, host should be `127.0.0.1:15432`. |
| `LEAPERONE_DATABASE_URL` | Leave unchanged until old workflow is retired | Current legacy secret may still point at PVE; do not use it for DE migrations. |
| `LEAPERONE_HK_DATABASE_URL` | Add if HK API workflow writes `.env` | HK API DB URL through WireGuard/private DE address. |
| `CLOUDFLARE_API_TOKEN` | Add if DNS cutover is automated | Prefer scoped token over global key. |
| `CLOUDFLARE_ZONE_LEAPER_ONE` | Add as variable or secret | Avoid zone lookup ambiguity. |
| `LEAPERONE_POSTHOG_KEY` | Add as repo variable if needed | Current workflow reads repo vars, but none are set in this repo. |
| `LEAPERONE_POSTHOG_HOST` | Add as repo variable if needed | Usually `https://us.i.posthog.com`. |

Avoid storing the DE Postgres superuser password in GitHub unless the workflow must create/drop databases. Prefer:

- Superuser password remains only on DE in `/opt/apps/postgres/production/.env`.
- GitHub Actions uses app role credentials for migrations.
- Initial DB creation/restoration is done manually or by an approved one-off script over SSH.

Server-side `.env` files needed:

- DE `/opt/apps/leaperone/production/.env`
- HK API fallback service `.env`

These files should include app credentials, provider keys, Sentry DSNs, payment keys, and DB URLs. They should not be committed.

## 6. Preflight Checklist

Run before any write operation.

### 6.1 Git and release readiness

- `leaperone/LEAPERone` main contains runtime role flags.
- `leaperone/leaperone-releases` contains `compose/leaperone`.
- `deploy-leaperone.yml` deploys to DE, or a separate DE workflow exists.
- HK API fallback workflow is separate from DE primary deploy.
- Required GitHub Secrets are present by name.

### 6.2 DE host readiness

On DE:

```bash
ssh root@de.leaper.one "docker network inspect leaperone-prod >/dev/null && docker ps | grep postgres-production"
ssh root@de.leaper.one "ss -ltnp | grep -E ':9800|:9801' || true"
ssh root@de.leaper.one "df -hT / /opt/apps"
```

Expected:

- `postgres-production` healthy.
- Ports chosen for web/api are free.
- Sufficient disk space.

### 6.3 PVE DB source readiness

Use PVE LXC 210 direct Postgres port for dump:

```bash
ssh root@pve.leaper.one "pct exec 210 -- runuser -u postgres -- psql -p 5433 -d leaperone_db -c 'SELECT current_database(), version();'"
ssh root@pve.leaper.one "pct exec 210 -- runuser -u postgres -- psql -p 5433 -d leaperone_db -c \"SELECT schemaname, relname FROM pg_stat_user_tables ORDER BY 1,2;\""
```

Expected:

- `public` tables plus `drizzle.__drizzle_migrations`.
- No unexpected schemas/extensions beyond `plpgsql`.

### 6.4 Application write freeze plan

Before dump, all writers must be frozen:

- Put `leaper.one` and `api.leaper.one` into maintenance or block API writes.
- Stop HK LEAPERone API/Web containers.
- Confirm no active sessions against PVE `leaperone_db`.

Do not dump while HK API is still accepting writes.

## 7. Dry Run

Do a dry run before production cutover.

### 7.1 Dump from PVE

```bash
STAMP="$(date -u +%Y%m%d%H%M%S)"
REMOTE_DIR="/root/db-migration/leaperone-${STAMP}"

ssh root@pve.leaper.one "set -euo pipefail
mkdir -p '${REMOTE_DIR}'
pct exec 210 -- runuser -u postgres -- pg_dump -p 5433 -d leaperone_db -Fc -Z 9 --no-owner --no-acl > '${REMOTE_DIR}/leaperone_db.dump'
cd '${REMOTE_DIR}'
sha256sum leaperone_db.dump > SHA256SUMS
ls -lh
cat SHA256SUMS
"
```

### 7.2 Copy to DE

```bash
DE_DIR="/opt/backups/leaperone-migration/${STAMP}"

ssh root@pve.leaper.one "ssh root@de.leaper.one 'mkdir -p ${DE_DIR}'"
ssh root@pve.leaper.one "scp -q ${REMOTE_DIR}/* root@de.leaper.one:${DE_DIR}/"
```

### 7.3 Restore to dry-run DB on DE

Use `leaperone_db_dryrun`, not the final DB:

```bash
ssh root@de.leaper.one "set -euo pipefail
cd '${DE_DIR}'
sha256sum -c SHA256SUMS
cd /opt/apps/postgres/production
PGPASS=\$(sed -n 's/^POSTGRES_PASSWORD=//p' .env)
docker exec -i -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'leaperone_db_dryrun' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS leaperone_db_dryrun;
CREATE DATABASE leaperone_db_dryrun WITH TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';
SQL
docker exec -i postgres-production pg_restore -U postgres -d leaperone_db_dryrun --no-owner --no-acl < '${DE_DIR}/leaperone_db.dump'
docker exec -e PGPASSWORD=\"\${PGPASS}\" postgres-production psql -U postgres -d leaperone_db_dryrun -P pager=off -c \"SELECT schemaname, relname FROM pg_stat_user_tables ORDER BY 1,2;\"
"
```

Dry-run pass criteria:

- Restore exits 0.
- 22 tables are present.
- `drizzle.__drizzle_migrations` exists.
- Row counts match source for key tables.

## 8. Production Cutover

### Phase 1: Maintenance and write freeze

1. Enable maintenance or stop traffic to old HK web/API.
2. Stop old HK LEAPERone containers.
3. Confirm PVE DB has no active app sessions:

   ```bash
   ssh root@pve.leaper.one "pct exec 210 -- runuser -u postgres -- psql -p 5433 -d postgres -P pager=off -c \"SELECT datname, usename, client_addr, state, count(*) FROM pg_stat_activity WHERE datname = 'leaperone_db' GROUP BY 1,2,3,4 ORDER BY count(*) DESC;\""
   ```

### Phase 2: Final dump and copy

Repeat the dump and copy from dry run with a new `STAMP`.

Record:

- `STAMP`
- dump path on PVE
- backup path on DE
- SHA256

### Phase 3: Create final DB and app role on DE

Example role name: `leaperone_app`.

The app role password should be generated and stored in:

- DE `/opt/apps/leaperone/production/.env`
- GitHub secret only if CI migrations need it
- HK fallback `.env` after WireGuard is ready

Create target DB:

```sql
CREATE ROLE leaperone_app LOGIN PASSWORD '<generated-password>';
CREATE DATABASE leaperone_db OWNER leaperone_app
  WITH TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';
```

Restore:

```bash
docker exec -i postgres-production pg_restore \
  -U postgres \
  --role=leaperone_app \
  -d leaperone_db \
  --no-owner \
  --no-acl \
  < /opt/backups/leaperone-migration/${STAMP}/leaperone_db.dump
```

After restore:

```sql
GRANT CONNECT ON DATABASE leaperone_db TO leaperone_app;
GRANT USAGE ON SCHEMA public, drizzle TO leaperone_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public, drizzle TO leaperone_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public, drizzle TO leaperone_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO leaperone_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO leaperone_app;
```

### Phase 4: Verify restored DB

Run source and target row-count comparison for all tables:

```sql
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY schemaname, relname;
```

Minimum checks:

- `public.user`
- `public.apikey`
- `public.credit_balance`
- `public.credit_usage`
- `public.recharge_credit`
- `public.image_generation`
- `drizzle.__drizzle_migrations`

### Phase 5: Deploy DE web/API

Deploy `compose/leaperone` to DE.

Check:

```bash
ssh root@de.leaper.one "cd /opt/apps/leaperone/production && docker compose ps"
ssh root@de.leaper.one "curl -fsS http://127.0.0.1:9800/api/health"
ssh root@de.leaper.one "curl -fsS http://127.0.0.1:9801/health"
ssh root@de.leaper.one "curl -fsS http://127.0.0.1:9801/v1/models >/dev/null"
```

Verify through nginx before DNS:

```bash
curl --resolve leaper.one:443:159.195.43.38 https://leaper.one/api/health
curl --resolve api.leaper.one:443:159.195.43.38 https://api.leaper.one/health
curl --resolve api.leaper.one:443:159.195.43.38 https://api.leaper.one/v1/models
```

### Phase 6: DNS cutover

Change Cloudflare:

| Record | From | To |
|---|---|---|
| `leaper.one` | `8.217.72.118` | `159.195.43.38` |
| `api.leaper.one` | `8.217.72.118` | `159.195.43.38` |
| `cn-hongkong.leaper.one` | keep/create `8.217.72.118` | unchanged |

If using Cloudflare Load Balancer later:

- Pool `de-api`: `159.195.43.38`
- Pool `hk-api`: `8.217.72.118`
- Policy: DE primary, HK fallback only
- Do not weight active-active until shared rate limiting is complete.

### Phase 7: Post-cutover validation

External checks:

```bash
curl -fsS https://leaper.one/api/health
curl -fsS https://api.leaper.one/health
curl -fsS https://api.leaper.one/v1/models
```

Product checks:

- Login via OAuth.
- Dashboard loads API keys and credit balance.
- Create/revoke API key.
- Call `/v1/chat/completions` with a low-cost model.
- Confirm credit usage row is inserted into DE `leaperone_db`.
- Test `/v1/images/generations` if image worker is enabled.
- Confirm Sentry receives web/api events.
- Confirm Stripe/Alipay callback URLs still work or run sandbox callbacks.

## 9. HK API Fallback Enablement

Only after DE production is stable:

1. Establish WireGuard or equivalent private path from HK to DE.
2. Allow HK source private IP to reach DE Postgres.
3. Configure HK API `.env`:

   ```text
   DATABASE_URL=postgresql://leaperone_app:<password>@<de-private-ip>:5432/leaperone_db
   RUN_MIGRATIONS=false
   ENABLE_IMAGE_WORKER=false
   ENABLE_EMAIL_LISTENER=false
   ```

4. Deploy API only to HK.
5. Verify with `cn-hongkong.leaper.one`:

   ```bash
   curl -fsS https://cn-hongkong.leaper.one/health
   curl -fsS https://cn-hongkong.leaper.one/v1/models
   ```

6. Add HK as manual DNS fallback or Cloudflare LB secondary.

## 10. Rollback Plan

### Before DE accepts writes

Rollback is simple:

1. Keep or re-enable maintenance.
2. Point `leaper.one` and `api.leaper.one` back to `8.217.72.118`.
3. Start old HK services.
4. Keep PVE `leaperone_db` as authority.
5. Drop or archive DE `leaperone_db`.

### After DE accepts writes

Rollback is not a DNS-only operation.

Options:

- Keep DE as database authority and point app traffic accordingly.
- Or freeze writes, dump DE `leaperone_db`, restore back to PVE, then point DNS back to HK.

Do not point traffic back to HK/PVE after DE has accepted writes unless a reverse migration has been completed.

## 11. Open Decisions

- Exact DE ports for LEAPERone web/API after `ss -ltnp` verification.
- Whether DNS cutover is manual, local script, or GitHub Action.
- Whether `LEAPERONE_DATABASE_URL` is repurposed or split into `LEAPERONE_DE_DATABASE_URL`.
- WireGuard address plan for HK -> DE Postgres.
- Whether image previews stay local temp files or move to OSS.
- Whether first DE deployment is stop/start or blue-green.

## 12. Execution Record

Executed on 2026-07-07 UTC / 2026-07-08 Asia/Shanghai.

- Final PVE dump stamp: `20260707155657`.
- Final DE restore: `leaperone_db` restored to DE PostgreSQL as `leaperone_app`; exact row counts matched PVE across 22 tables before cutover.
- Deployment tag: `web-v0.1.12` (`LEAPERone` commit `49cc38b`).
- Successful deploy workflow: `leaperone-releases` run `28881078502`.
- DE runtime:
  - `leaperone-web-production` healthy on `127.0.0.1:9800`.
  - `leaperone-api-production` healthy on `127.0.0.1:9801`.
  - DE `leaperone_db` has active `leaperone_app` connections.
- DNS cutover:
  - `A leaper.one -> 159.195.43.38`.
  - `A api.leaper.one -> 159.195.43.38`.
  - `CNAME www.leaper.one -> leaper.one`.
- Public validation from PVE and HK succeeded for:
  - `https://leaper.one/api/health`
  - `https://api.leaper.one/health`
  - `https://www.leaper.one/api/health`
- HK legacy containers were stopped and their Docker restart policy was changed to `no` to avoid accidental writes to the old PVE database. For a rollback to HK, restore the restart policy or recreate via compose before starting traffic:

  ```bash
  ssh leaperone@8.217.72.118 -p 220 "docker update --restart=always leaperone-web-leaperone-api-1 leaperone-web-leaperone-web-1"
  ssh leaperone@8.217.72.118 -p 220 "cd ~/services/leaperone-web && docker compose up -d"
  ```
