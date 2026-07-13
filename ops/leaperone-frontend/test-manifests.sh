#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/leaperone-manifest-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/certs"
cp -R "$ROOT/compose/leaperone-www" "$TMP/www"
cp -R "$ROOT/compose/leaperone-dashboard" "$TMP/dashboard"

cat > "$TMP/bin/docker" <<'MOCK'
#!/bin/sh
case "${1:-}:${2:-}" in
  network:inspect|compose:config) exit 0 ;;
  ps:*) exit 0 ;;
esac
exit 1
MOCK
cat > "$TMP/bin/ss" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod 0755 "$TMP/bin/docker" "$TMP/bin/ss"

printf 'fixture\n' > "$TMP/certs/app.crt"
printf 'fixture\n' > "$TMP/certs/alipay.crt"
printf 'fixture\n' > "$TMP/certs/root.crt"

cat > "$TMP/www/.env" <<'ENV'
DEPLOY_ENV=production
WWW_PORT=9820
NGINX_ROUTING_MODE=off
ENV
cat > "$TMP/www/.env.www" <<'ENV'
API_URL="https://api.leaper.one"
NEXT_PUBLIC_DASHBOARD_URL='https://dashboard.leaper.one'
NEXT_PUBLIC_SENTRY_DSN=https://fixturepublic@sentry.leaperone.cn/10
SENTRY_DSN=https://fixturepublic@sentry.leaperone.cn/10
SENTRY_PROJECT=leaperone-www
ENV

cat > "$TMP/dashboard/.env" <<ENV
DEPLOY_ENV=production
DASHBOARD_PORT=9821
ALIPAY_CERT_HOST_DIR=$TMP/certs
ENV
cat > "$TMP/dashboard/.env.dashboard" <<'ENV'
DATABASE_URL=postgresql://app:fixture@postgres:5432/leaperone_db
BETTER_AUTH_SECRET=fixture-secret
BASE_URL="https://dashboard.leaper.one"
BETTER_AUTH_URL=https://dashboard.leaper.one
AUTH_COOKIE_DOMAIN=""
API_URL=https://api.leaper.one
PAYMENT_WEBHOOK_BASE_URL=https://api.leaper.one
GITHUB_CLIENT_ID=github-client
GITHUB_CLIENT_SECRET=github-secret
GOOGLE_CLIENT_ID=google-client
GOOGLE_CLIENT_SECRET=google-secret
STRIPE_SECRET_KEY=sk_live_fixture
ALIPAY_APP_ID=alipay-app
ALIPAY_APP_PRIVATE_KEY=alipay-private
ALIPAY_SIGN_MODE=cert
ALIPAY_APP_CERT_PATH=/app/alipay-cert/app.crt
ALIPAY_PUBLIC_CERT_PATH=/app/alipay-cert/alipay.crt
ALIPAY_ROOT_CERT_PATH=/app/alipay-cert/root.crt
HMZF_ENABLED=false
NEXT_PUBLIC_SENTRY_DSN=https://fixturepublic@sentry.leaperone.cn/11
SENTRY_DSN=https://fixturepublic@sentry.leaperone.cn/11
SENTRY_PROJECT=leaperone-dashboard
ENV

chmod 0600 "$TMP/www/.env" "$TMP/www/.env.www" \
  "$TMP/dashboard/.env" "$TMP/dashboard/.env.dashboard"

SHA=0123456789abcdef0123456789abcdef01234567
DIGEST=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
PATH="$TMP/bin:$PATH" WWW_IMAGE_TAG="www-$SHA" WWW_IMAGE_DIGEST="$DIGEST" "$TMP/www/preflight.sh" >/dev/null
PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh" >/dev/null

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "ERROR: expected manifest validation failure: $*" >&2
    exit 1
  fi
}

cp "$TMP/www/.env.www" "$TMP/www/.env.www.valid"
printf 'DATABASE_URL=forbidden\n' >> "$TMP/www/.env.www"
expect_failure env PATH="$TMP/bin:$PATH" WWW_IMAGE_TAG="www-$SHA" WWW_IMAGE_DIGEST="$DIGEST" "$TMP/www/preflight.sh"
mv "$TMP/www/.env.www.valid" "$TMP/www/.env.www"
chmod 0600 "$TMP/www/.env.www"

cp "$TMP/www/.env.www" "$TMP/www/.env.www.valid"
sed 's#sentry\.leaperone\.cn#evil.example#' \
  "$TMP/www/.env.www" > "$TMP/www/.env.www.invalid"
mv "$TMP/www/.env.www.invalid" "$TMP/www/.env.www"
chmod 0600 "$TMP/www/.env.www"
expect_failure env PATH="$TMP/bin:$PATH" WWW_IMAGE_TAG="www-$SHA" WWW_IMAGE_DIGEST="$DIGEST" "$TMP/www/preflight.sh"

cp "$TMP/dashboard/.env.dashboard" "$TMP/dashboard/.env.dashboard.valid"
sed 's/^AUTH_COOKIE_DOMAIN=.*/AUTH_COOKIE_DOMAIN=.leaper.one/' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.invalid"
mv "$TMP/dashboard/.env.dashboard.invalid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
expect_failure env PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh"

cp "$TMP/dashboard/.env.dashboard.valid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
sed 's/^HMZF_ENABLED=.*/HMZF_ENABLED=true/' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.invalid"
mv "$TMP/dashboard/.env.dashboard.invalid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
expect_failure env PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh"

cp "$TMP/dashboard/.env.dashboard.valid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
sed 's#^ALIPAY_ROOT_CERT_PATH=.*#ALIPAY_ROOT_CERT_PATH=/tmp/outside-root.crt#' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.invalid"
mv "$TMP/dashboard/.env.dashboard.invalid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
expect_failure env PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh"

cp "$TMP/dashboard/.env.dashboard.valid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
sed 's/^STRIPE_SECRET_KEY=.*/STRIPE_SECRET_KEY=sk_test_forbidden/' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.invalid"
mv "$TMP/dashboard/.env.dashboard.invalid" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
expect_failure env PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh"

cp "$TMP/dashboard/.env.dashboard.valid" "$TMP/dashboard/.env.dashboard"
sed -e 's/^ALIPAY_SIGN_MODE=.*/ALIPAY_SIGN_MODE=key/' \
    -e 's#^ALIPAY_APP_CERT_PATH=.*#ALIPAY_APP_CERT_PATH=#' \
    -e 's#^ALIPAY_PUBLIC_CERT_PATH=.*#ALIPAY_PUBLIC_CERT_PATH=#' \
    -e 's#^ALIPAY_ROOT_CERT_PATH=.*#ALIPAY_ROOT_CERT_PATH=#' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.key"
printf 'ALIPAY_PUBLIC_KEY=fixture-public-key\n' >> "$TMP/dashboard/.env.dashboard.key"
mv "$TMP/dashboard/.env.dashboard.key" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh" >/dev/null

cp "$TMP/dashboard/.env.dashboard.valid" "$TMP/dashboard/.env.dashboard"
sed 's/^HMZF_ENABLED=.*/HMZF_ENABLED=true/' \
  "$TMP/dashboard/.env.dashboard" > "$TMP/dashboard/.env.dashboard.hmzf"
printf 'HMZF_GATEWAY_URL=https://gateway.example\nHMZF_MCH_NO=merchant\nHMZF_APP_ID=app\nHMZF_APP_KEY=key\n' \
  >> "$TMP/dashboard/.env.dashboard.hmzf"
mv "$TMP/dashboard/.env.dashboard.hmzf" "$TMP/dashboard/.env.dashboard"
chmod 0600 "$TMP/dashboard/.env.dashboard"
PATH="$TMP/bin:$PATH" DASHBOARD_IMAGE_TAG="dashboard-$SHA" DASHBOARD_IMAGE_DIGEST="$DIGEST" "$TMP/dashboard/preflight.sh" >/dev/null

echo "Runtime env manifest positive and rejection tests passed"
