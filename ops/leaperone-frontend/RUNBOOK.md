# LEAPERone one-shot frontend cutover

This runbook deploys WWW and Dashboard from one pinned LEAPERone source SHA,
verifies both immutable images on the Germany host, and performs one atomic
Nginx replacement. There is no candidate mode, temporary `next.leaper.one`,
legacy Web upstream, or staged routing state.

The frontend workflow does not migrate the database or restart the API. The
separate `deploy-leaperone` workflow is API-only: it builds and deploys only
`leaperone-api`, while preserving its existing reviewed database migration
step before container replacement.

## Final topology

| Origin | Container | Loopback listener |
|---|---|---|
| `leaper.one`, `www.leaper.one` | `leaperone-www-production` | `127.0.0.1:9820` |
| `dashboard.leaper.one` | `leaperone-dashboard-production` | `127.0.0.1:9821` |
| `api.leaper.one` | `leaperone-api-production` | `127.0.0.1:9801` |

The root host retains only two exact payment callback aliases:

- `/api/recharge/notify/stripe` → API `/webhooks/payments/stripe`
- `/api/recharge/notify/alipay` → API `/webhooks/payments/alipay`

These aliases protect already-created orders and externally configured Stripe
webhooks. They do not route through the legacy Web and can be removed after the
provider retry window and old Alipay orders have been audited.

There are deliberately no root-domain aliases for CLI, EnvX, Better Auth,
device authorization, Dashboard pages, or the old CLI POST exchange flow.

## Required pre-cutover state

1. `leaperone/LEAPERone` main must be green and the dispatch must pin its exact
   40-character source SHA.
2. `@leaperone/cli` 0.1.11 must be published before cutover. Version 0.1.10
   calls the root domain and will stop working; users must upgrade.
3. `dashboard.leaper.one` DNS and GitHub/Google OAuth callbacks must already
   point to the final Dashboard origin. Existing root host-only sessions will
   require a new login.
4. EnvX root-domain clients are not supported by this cutover and may remain
   unavailable until their separate migration is completed.
5. Confirm Stripe's configured webhook endpoint uses
   `https://api.leaper.one/webhooks/payments/stripe`. Keep the exact root alias
   until this is verified and the provider retry window has passed.
6. Stop creating legacy-root Alipay notify URLs and allow at least the order
   timeout window to drain. The exact root alias remains as a settlement
   safeguard.
7. The certificate at `/etc/nginx/ssl/leaper.one/fullchain.cer` must cover
   `leaper.one`, `www.leaper.one`, `api.leaper.one`, and
   `dashboard.leaper.one`.
8. The DE host must have the `leaperone-prod` Docker network, API `:9801`, and
   the four root-owned mode `0600` frontend manifests described below.

## Server manifests

`/opt/apps/leaperone-www/production/.env`:

```dotenv
DEPLOY_ENV=production
WWW_PORT=9820
LEAPERONE_TLS_CERT_DIR=/etc/nginx/ssl/leaper.one
```

`/opt/apps/leaperone-www/production/.env.www` contains only the WWW allowlist,
including:

```dotenv
API_URL=https://api.leaper.one
NEXT_PUBLIC_DASHBOARD_URL=https://dashboard.leaper.one
NEXT_PUBLIC_SENTRY_DSN=<www-public-dsn>
SENTRY_DSN=<same-www-public-dsn>
SENTRY_PROJECT=leaperone-www
```

`/opt/apps/leaperone-dashboard/production/.env`:

```dotenv
DEPLOY_ENV=production
DASHBOARD_PORT=9821
ALIPAY_CERT_HOST_DIR=/opt/apps/leaperone/production/alipay-cert
```

`/opt/apps/leaperone-dashboard/production/.env.dashboard` contains the
Dashboard-owned database, Better Auth, OAuth, payment creation, provider, and
public telemetry values. Its production origins must be exact:

```dotenv
BASE_URL=https://dashboard.leaper.one
BETTER_AUTH_URL=https://dashboard.leaper.one
AUTH_COOKIE_DOMAIN=
API_URL=https://api.leaper.one
PAYMENT_WEBHOOK_BASE_URL=https://api.leaper.one
SENTRY_PROJECT=leaperone-dashboard
```

Both preflight scripts reject unknown runtime keys, unsafe file ownership or
mode, mutable image tags, missing digests, invalid payment configuration, and
incorrect production origins before pulling or changing containers.

## One dispatch

Resolve the merged source SHA and dispatch the paired workflow once:

```bash
SOURCE_SHA=<full-leaperone-main-sha>
gh api repos/leaperone/leaperone-releases/dispatches \
  -f event_type=deploy-leaperone-frontends \
  -F 'client_payload[ref]=main' \
  -F "client_payload[source_sha]=$SOURCE_SHA"
```

The workflow is serialized by the global
`leaperone-frontends-production` concurrency group and performs:

1. Validate and pin one source SHA.
2. Build, publish, deploy, health-check, and verify the Dashboard RepoDigest.
3. Build, publish, deploy, health-check, and verify the WWW RepoDigest.
4. Recheck both RepoDigests plus WWW, Dashboard database readiness, and API
   health from the DE host.
5. Back up the current Nginx config and shared headers under one UTC stamp.
6. Atomically install the final config, run `nginx -t`, and reload.
7. Smoke all three HTTPS origins through local SNI with `curl --resolve`.
8. Automatically restore the previous Nginx pair if syntax, reload, or final
   route smoke fails.
9. Append pair-level root-only evidence to
   `/var/lib/leaperone/deployments/frontend-cutovers.jsonl`.

The public switch occurs only in step 6, after both new components have passed
their image and runtime gates.

## Verification

```bash
curl -fsS https://leaper.one/api/health
curl -fsS https://dashboard.leaper.one/api/ready
curl -fsS https://api.leaper.one/health

docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' \
  leaperone-www-production leaperone-dashboard-production

tail -n 5 /var/lib/leaperone/deployments/frontend-cutovers.jsonl
```

Verify login, OAuth callbacks, Passkeys, CLI 0.1.11, and one separately
approved payment flow. Do not use a real payment merely as a generic smoke
test.

## Independent releases after cutover

`deploy-leaperone-www` and `deploy-leaperone-dashboard` remain available for
routine component releases. They share the same production concurrency group,
deploy immutable images, and never edit Nginx. Use the paired workflow whenever
both components must move on one source SHA.

## API-only releases and legacy Web retirement

`deploy-leaperone` accepts only `components=api` (or the default empty
component payload), builds only `leaperone-api`, pushes only API tags, runs the
existing API-owned migration step, and deploys the `compose/leaperone` project.
That Compose project contains only `leaperone-api-production`; it has no Web
service, `.env.web` dependency, port `9800`, or Nginx payload.

```bash
SOURCE_SHA=<full-leaperone-main-sha>
gh api repos/leaperone/leaperone-releases/dispatches \
  -f event_type=deploy-leaperone \
  -F 'client_payload[ref]=main' \
  -F 'client_payload[components]=api' \
  -F "client_payload[source_sha]=$SOURCE_SHA"
```

The first API-only deploy uses `docker compose up --remove-orphans`, so a
stopped `leaperone-web-production` container is removed instead of restarted.
Before that deploy, retain its immutable image reference, image ID, RepoDigest,
and root-only `.env.web` as rollback evidence. After the observation window,
remove stale `WEB_IMAGE_TAG`, `WEB_PORT`, and `INSTALL_NGINX_CONF` entries from
the server `.env`, then archive or securely remove `.env.web` and any obsolete
`compose/leaperone/nginx` payload left by older overwrite-only syncs.

Before the generic deployer runs, the DE workflow handles overwrite-only SCP
drift explicitly: any server-resident legacy Nginx installer or config is
copied to `/var/lib/leaperone/retired-release-payloads`, checksummed, recorded
with the releases SHA, and removed from the active project directory. The
generic deployer additionally skips the entire post-deploy scripts phase for
the `leaperone` project, so an unknown stale installer cannot execute.

Do not interpret the API migration step as permission to migrate during a
frontend release. WWW, Dashboard, and the paired cutover remain explicitly
`"migration":"none"`.

## Rollback

The cutover log prints a UTC backup stamp. Restore that exact Nginx pair with:

```bash
bash ops/leaperone-frontend/rollback-nginx.sh 20260713T120000Z
```

The rollback script takes the same global host lock, saves a rescue copy of
the current files, validates the requested backup with `nginx -t`, reloads, and
restores the rescue files if rollback fails.

Frontend image rollback uses the immutable refs and digests recorded in
`frontend-deployments.jsonl`; never infer a rollback from `latest`.

The legacy Web is a cold rollback artifact, not an active service or routing
compatibility layer. While its stopped container still exists, restore it with
`docker start leaperone-web-production` and verify
`http://127.0.0.1:9800/api/health` before restoring an Nginx backup that points
to `:9800`. After orphan cleanup removes the container, recreate it only from
the reviewed immutable Web image and preserved root-only manifest before using
that Nginx backup. Normal API, WWW, and Dashboard releases must never start it.
