# LEAPERone split frontend deployment runbook

This runbook deploys the public WWW and authenticated Dashboard independently
on the Germany host. It does not migrate the database, restart the API, change
DNS, or provision credentials.

## Target layout

| Component | Container | Origin listener | Image tag |
|---|---|---|---|
| Legacy Web compatibility | `leaperone-web-production` | `127.0.0.1:9800` | retained during compatibility window |
| Existing API | `leaperone-api-production` | `127.0.0.1:9801` | unchanged |
| WWW | `leaperone-www-production` | `127.0.0.1:9820` | `www-<source-sha>` |
| Dashboard | `leaperone-dashboard-production` | `127.0.0.1:9821` | `dashboard-<source-sha>` |

The frontend workflows have independent concurrency groups. Neither workflow
contains a migration job or references the `leaperone` Web/API compose project.
The legacy Web/API workflow explicitly builds only `leaperone-web` and
`leaperone-api`; its old nginx installer is a no-op so a later API release
cannot overwrite staged or cut-over routing.

## External prerequisites

Before dispatching either workflow:

1. `leaperone/LEAPERone` must contain production-ready WWW/Dashboard
   Dockerfiles, `/api/health` routes, Dashboard `/api/ready`, and
   `leaperone-www` / `leaperone-dashboard` services in
   `docker/docker-compose-build.yml`. Web/WWW/Dashboard Dockerfiles must mount
   BuildKit secret `next_server_actions_encryption_key`, and build Compose must
   read it from `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY_FILE`.
2. Repository secrets used by existing builds must be present:
   `ACCESS_TOKEN`, `SENTRY_AUTH_TOKEN`,
   `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, registry credentials, and DE SSH
   credentials.
3. Optional build variables should be reviewed:
   `LEAPERONE_TURNSTILE_SITE_KEY`, `LEAPERONE_POSTHOG_KEY`,
   `LEAPERONE_POSTHOG_HOST`, `LEAPERONE_GOOGLE_ANALYTICS_ID`, and
   `LEAPERONE_SENTRY_TRACES_SAMPLE_RATE`.
4. Create Sentry projects `leaperone-www` and `leaperone-dashboard`, then set
   repository variables `LEAPERONE_WWW_SENTRY_DSN` and
   `LEAPERONE_DASHBOARD_SENTRY_DSN`. Releases are isolated as
   `leaperone-www@<source-sha>` and `leaperone-dashboard@<source-sha>`.
   `SENTRY_AUTH_TOKEN` is build-only: workflows write it to a mode `0600`
   `$RUNNER_TEMP` file, pass only `SENTRY_AUTH_TOKEN_FILE` to Compose/BuildKit,
   and remove the file with an `always()` cleanup step.
   `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` follows the same second-file BuildKit
   secret flow so Server Action encryption remains stable across releases
   without entering build args, environment provenance, or runtime manifests.
5. The certificate at `/etc/nginx/ssl/leaper.one/fullchain.cer` must cover
   `leaper.one`, `www.leaper.one`, `api.leaper.one`, `dashboard.leaper.one`,
   and `next.leaper.one`. The installer verifies every hostname.
6. Candidate DNS must point both `dashboard.leaper.one` and `next.leaper.one`
   at the DE origin before candidate mode is enabled. Dashboard deliberately
   uses its final hostname during candidate validation.
7. The DE host must provide `curl`, `flock`, `openssl`, and `nginx`; the atomic
   installer checks these commands before touching live configuration.

## Server environment manifests

Create all files as `root:root`, mode `0600`, without committing them. Runtime
manifests are parsed as dotenv data without `source` or `eval`; malformed,
duplicate, or unknown keys fail before any image pull or container change.

### WWW

`/opt/apps/leaperone-www/production/.env` is compose-only:

```dotenv
DEPLOY_ENV=production
WWW_PORT=9820
NGINX_ROUTING_MODE=off
LEAPERONE_TLS_CERT_DIR=/etc/nginx/ssl/leaper.one
```

`NGINX_ROUTING_MODE` accepts only `off`, `candidate`, or `cutover`.

`/opt/apps/leaperone-www/production/.env.www` is public/stateless runtime data:

```dotenv
API_URL=https://api.leaper.one
NEXT_PUBLIC_DASHBOARD_URL=https://dashboard.leaper.one
NEXT_PUBLIC_POSTHOG_KEY=
NEXT_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
NEXT_PUBLIC_GOOGLE_ANALYTICS_ID=
NEXT_PUBLIC_SENTRY_DSN=<www-public-dsn>
NEXT_PUBLIC_SENTRY_TRACES_SAMPLE_RATE=0.1
SENTRY_DSN=<www-public-dsn>
SENTRY_TRACES_SAMPLE_RATE=0.1
SENTRY_ORG=leaperone
SENTRY_PROJECT=leaperone-www
SENTRY_URL=https://sentry.leaperone.cn/
SENTRY_RELEASE=leaperone-www@<source-sha>
```

The preflight rejects database URLs, auth/OAuth secrets, payment credentials,
provider secrets, `SENTRY_AUTH_TOKEN`, and every other key outside the explicit
WWW allowlist. Both production origins are exact and cannot point at localhost
or a candidate Dashboard hostname. `NEXT_PUBLIC_SENTRY_DSN` and `SENTRY_DSN`
are required, must match, and must have the public-only form
`https://<public-key>@sentry.leaperone.cn/<project-id>`;
`SENTRY_PROJECT` must be `leaperone-www`.

### Dashboard

`/opt/apps/leaperone-dashboard/production/.env` is compose-only:

```dotenv
DEPLOY_ENV=production
DASHBOARD_PORT=9821
ALIPAY_CERT_HOST_DIR=/opt/apps/leaperone/production/alipay-cert
```

`/opt/apps/leaperone-dashboard/production/.env.dashboard` contains only the
Dashboard-owned runtime manifest. Production UI prerequisites are fail-closed:

```dotenv
DATABASE_URL=postgresql://<app-role>@postgres:5432/leaperone_db
BETTER_AUTH_SECRET=<same reviewed production secret>
BASE_URL=https://dashboard.leaper.one
BETTER_AUTH_URL=https://dashboard.leaper.one
AUTH_COOKIE_DOMAIN=
API_URL=https://api.leaper.one
PAYMENT_WEBHOOK_BASE_URL=https://api.leaper.one

GITHUB_CLIENT_ID=<non-empty>
GITHUB_CLIENT_SECRET=<non-empty>
GOOGLE_CLIENT_ID=<non-empty>
GOOGLE_CLIENT_SECRET=<non-empty>

STRIPE_SECRET_KEY=sk_live_<production-key>

ALIPAY_APP_ID=<non-empty>
ALIPAY_APP_PRIVATE_KEY=<non-empty>
ALIPAY_SIGN_MODE=cert

HMZF_ENABLED=false

NEXT_PUBLIC_SENTRY_DSN=https://<public-key>@sentry.leaperone.cn/<project-id>
SENTRY_DSN=https://<public-key>@sentry.leaperone.cn/<project-id>
SENTRY_PROJECT=leaperone-dashboard
```

GitHub and Google OAuth credentials, production Stripe key, Alipay app/private
key, and dedicated Sentry values are mandatory because their UI surfaces are
enabled in production. Stripe `sk_test_*` keys are rejected. Optional origin
and telemetry settings may be added only from the allowlist enforced by
`preflight.sh`. Webhook verification secrets, API provider credentials, EnvX
encryption keys, control-plane secrets, Server Actions keys, and
`SENTRY_AUTH_TOKEN` are forbidden from runtime manifests.

For Alipay certificate mode:

```dotenv
ALIPAY_SIGN_MODE=cert
ALIPAY_APP_CERT_PATH=/app/alipay-cert/appCertPublicKey.crt
ALIPAY_PUBLIC_CERT_PATH=/app/alipay-cert/alipayCertPublicKey_RSA2.crt
ALIPAY_ROOT_CERT_PATH=/app/alipay-cert/alipayRootCert.crt
```

Every non-empty certificate path must be canonical and remain under the
read-only `/app/alipay-cert` mount. Preflight also verifies that it maps to an
existing file in `ALIPAY_CERT_HOST_DIR`.

For Alipay public-key mode, use `ALIPAY_SIGN_MODE=key` and provide a non-empty
`ALIPAY_PUBLIC_KEY`; certificate paths may be absent or empty.

When `HMZF_ENABLED=true`, all of `HMZF_GATEWAY_URL`, `HMZF_MCH_NO`,
`HMZF_APP_ID`, and `HMZF_APP_KEY` are required. With `false`, those provider
values may be omitted.

Dashboard Sentry DSNs follow the same public-only hostname/shape validation as
WWW and must match each other; `SENTRY_PROJECT` must equal
`leaperone-dashboard`.

## Build and local candidate deployment

Dispatch only `main` or a component tag (`www-vX.Y.Z` /
`dashboard-vX.Y.Z`). Arbitrary branches, PR refs, malformed tags, and mutable
image tags fail closed. Registry push captures the manifest digest; production
Compose receives `tag@sha256:digest`, not a tag alone.

Deploy Dashboard first, then WWW while `NGINX_ROUTING_MODE=off`:

```bash
gh api repos/leaperone/leaperone-releases/dispatches \
  -f event_type=deploy-leaperone-dashboard \
  -F 'client_payload[ref]=main' \
  -F 'client_payload[source_sha]=<full-main-sha>'

gh api repos/leaperone/leaperone-releases/dispatches \
  -f event_type=deploy-leaperone-www \
  -F 'client_payload[ref]=main' \
  -F 'client_payload[source_sha]=<full-main-sha>'
```

Verify loopback candidates without changing root routing:

```bash
curl --fail http://127.0.0.1:9820/api/health
curl --fail http://127.0.0.1:9821/api/ready
curl --fail http://127.0.0.1:9801/health
curl --fail http://127.0.0.1:9800/api/health
docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' \
  leaperone-www-production leaperone-dashboard-production
```

After pull/up and all component gates pass, deployment verifies the container
image RepoDigest against the registry digest captured by CI. Only then it
appends a root-only record to:

```text
/var/lib/leaperone/deployments/frontend-deployments.jsonl
```

The directory is mode `0700`, the JSONL file is mode `0600`, and appends are
serialized with `flock`. Each record contains component, source SHA, releases
repository SHA, immutable image ref, manifest digest, UTC timestamp, and
`"migration":"none"`.

## Staged nginx candidate mode

After candidate DNS and certificate SANs are ready, set:

```dotenv
NGINX_ROUTING_MODE=candidate
```

Redeploy WWW. Candidate mode atomically installs this routing without changing
the root product entry:

- `leaper.one` / `www.leaper.one` remain on legacy Web `:9800`.
- `api.leaper.one` remains on API `:9801`.
- `dashboard.leaper.one` reaches Dashboard `:9821` using its final hostname.
- `next.leaper.one` reaches WWW `:9820`.

Use this stage for real OAuth callbacks, Passkeys, host-only cookie behavior,
browser navigation, Dashboard payment creation, and WWW links. WWW is built and
run with `NEXT_PUBLIC_DASHBOARD_URL=https://dashboard.leaper.one`.

## Atomic cutover mode

After candidate acceptance, set `NGINX_ROUTING_MODE=cutover` and redeploy WWW.
For candidate and cutover modes, the installer:

1. Rechecks WWW health, Dashboard database readiness, API health, and legacy
   Web health without changing nginx.
2. Verifies the certificate covers all five hostnames.
3. Takes an exclusive host lock.
4. Backs up the live config and records absence markers where appropriate.
5. Stages and replaces the selected mode config and shared headers.
6. Runs `nginx -t` before reload.
7. Restores the previous files and reloads them if validation or reload fails.

Cutover ownership and compatibility matrix:

- Root browser `/dashboard`, `/admin`, `/signin`, `/signout`, `/device`, and
  `/auth/cli` paths return `302 https://dashboard.leaper.one$request_uri`,
  preserving the complete path and query.
- Root Better Auth `/api/auth/*` and device `/api/device/*` proxy to Dashboard
  with `Host dashboard.leaper.one` and `X-Forwarded-Host` set to the root host.
- Root legacy CLI aliases and EnvX proxy transparently to API `:9801` with
  `Host api.leaper.one`; method, body, Authorization, URI, and envelope remain
  unchanged.
- Exact `PUT /api/v1/cli/auth/exchange` and other non-POST methods go to the
  API legacy atomic exchange adapter. Exact POST temporarily goes to legacy Web
  `:9800` only for already-open authorization pages. This exact location wins
  before the general CLI prefix. After the documented compatibility window,
  replace POST fallback with `410` in a reviewed release.
- Exact legacy Stripe and Alipay notify paths rewrite to
  `/webhooks/payments/stripe` and `/webhooks/payments/alipay` on API `:9801`.
- Public root pages and `/api/search` are served by WWW `:9820`.
- `next.leaper.one` remains available on WWW `:9820` during the observation
  window and can be removed in a later reviewed routing release.
- `api.leaper.one` remains on the existing API container.

Smoke tests must cover redirects and transparent proxies:

```bash
curl -fsSI 'https://leaper.one/dashboard/settings?tab=api' \
  | grep -F 'location: https://dashboard.leaper.one/dashboard/settings?tab=api'
curl -fsS https://leaper.one/api/v1/cli/docs
curl -fsS https://leaper.one/api/v1/envx/<namespace>/<project>/pull
curl -fsS https://api.leaper.one/health
```

Do not trigger real payments without separately approved channel and amount.

Repository-side routing assertions and syntax checks:

```bash
bash ops/leaperone-frontend/test-routing.sh
bash ops/leaperone-frontend/test-manifests.sh
bash ops/leaperone-frontend/test-workflow-contracts.sh
bash -n compose/leaperone-www/scripts/10-install-nginx-conf.sh \
  compose/leaperone-www/preflight.sh \
  compose/leaperone-dashboard/preflight.sh
```

## Rollback

### Nginx routing

Every candidate/cutover install prints a UTC rollback stamp. From a reviewed
checkout, copy and run:

```bash
bash ops/leaperone-frontend/rollback-nginx.sh 20260713T120000Z
```

It backs up the current files, restores the selected pair, runs `nginx -t`,
reloads, and restores the pre-rollback files if rollback fails. Rolling back a
cutover to its immediately preceding candidate backup restores root traffic to
legacy `:9800` while retaining real candidate hostnames.

### Frontend image

Old immutable images are retained. Select a reviewed deployment record first;
do not infer a rollback solely from a mutable registry alias:

```bash
tail -n 20 /var/lib/leaperone/deployments/frontend-deployments.jsonl
```

For the selected record, verify/pull its recorded `image_ref@image_digest`, then
deploy the recorded SHA tag together with that exact digest:

```bash
cd /opt/apps/leaperone-www/production
docker pull '<recorded-image-ref>@<recorded-image-digest>'
WWW_IMAGE_TAG=www-<previous-source-sha> \
WWW_IMAGE_DIGEST=<recorded-image-digest> \
  docker compose pull www
WWW_IMAGE_TAG=www-<previous-source-sha> \
WWW_IMAGE_DIGEST=<recorded-image-digest> \
  docker compose up -d --wait --wait-timeout 180 www

cd /opt/apps/leaperone-dashboard/production
docker pull '<recorded-image-ref>@<recorded-image-digest>'
DASHBOARD_IMAGE_TAG=dashboard-<previous-source-sha> \
DASHBOARD_IMAGE_DIGEST=<recorded-image-digest> \
  docker compose pull dashboard
DASHBOARD_IMAGE_TAG=dashboard-<previous-source-sha> \
DASHBOARD_IMAGE_DIGEST=<recorded-image-digest> \
  docker compose up -d --wait --wait-timeout 180 dashboard
```

If a historical record is unavailable, inspect the SHA tag in the registry and
record/verify its digest before rollback. Never roll back by an unchecked tag.

Image rollback does not run migrations or restart `leaperone-api-production`.
Keep the reviewed legacy compatibility container and immutable image available
through the CLI/payment compatibility window. Do not treat an arbitrary
pre-migration `web-latest` image as a safe Dashboard rollback.
