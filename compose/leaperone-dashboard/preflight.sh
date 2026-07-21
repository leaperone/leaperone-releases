#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -f .env ]; then
  set -a
  # Root .env is compose-only; runtime secrets are parsed below without eval.
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_private_file() {
  local path="$1"
  local mode
  local owner
  [ -f "$path" ] || fail "$path is missing"
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
  [ "$mode" = "600" ] || fail "$path must have mode 0600 (found $mode)"
  owner="$(stat -c '%u:%g' "$path" 2>/dev/null || stat -f '%u:%g' "$path")"
  [ "$owner" = "0:0" ] || fail "$path must be owned by root:root (found $owner)"
}

manifest_keys() {
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) exit 2
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      if (seen[key]++) exit 3
      value = substr(line, index(line, "=") + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" || first == "\047") && (last != first || length(value) < 2)) exit 4
      print key
    }
  ' "$1"
}

dotenv_value() {
  awk -v wanted="$2" '
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      if (key != wanted) next
      value = substr(line, index(line, "=") + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if (first == "\"" || first == "\047") {
        if (last != first || length(value) < 2) exit 4
        value = substr(value, 2, length(value) - 2)
      }
      print value
      found++
    }
    END { if (found != 1) exit 5 }
  ' "$1"
}

require_value() {
  local file="$1"
  local key="$2"
  local value
  if ! value="$(dotenv_value "$file" "$key")"; then
    fail "$file must contain exactly one valid $key assignment"
  fi
  [ -n "$value" ] || fail "$key must not be empty"
}

require_exact_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local value
  if ! value="$(dotenv_value "$file" "$key")"; then
    fail "$file must contain exactly one valid $key assignment"
  fi
  [ "$value" = "$expected" ] || fail "$key must equal $expected"
}

require_sentry_manifest() {
  local file="$1"
  local expected_project="$2"
  local public_dsn
  local server_dsn
  local project

  if ! public_dsn="$(dotenv_value "$file" NEXT_PUBLIC_SENTRY_DSN)" || [ -z "$public_dsn" ]; then
    fail "$file requires a non-empty NEXT_PUBLIC_SENTRY_DSN"
  fi
  if ! server_dsn="$(dotenv_value "$file" SENTRY_DSN)" || [ -z "$server_dsn" ]; then
    fail "$file requires a non-empty SENTRY_DSN"
  fi
  [ "$public_dsn" = "$server_dsn" ] || fail "public and server Sentry DSNs must match"
  [[ "$public_dsn" =~ ^https://[A-Za-z0-9._-]+@sentry\.leaperone\.cn/[0-9]+$ ]] || \
    fail "Sentry DSN must contain only a public key and use https://sentry.leaperone.cn/<project-id>"

  if ! project="$(dotenv_value "$file" SENTRY_PROJECT)"; then
    fail "$file requires SENTRY_PROJECT"
  fi
  [ "$project" = "$expected_project" ] || fail "SENTRY_PROJECT must equal $expected_project"
}

assert_cert_path() {
  local key="$1"
  local required="$2"
  local value=""
  local relative_path
  if value="$(dotenv_value .env.dashboard "$key" 2>/dev/null)"; then
    if [ -z "$value" ]; then
      [ "$required" = "false" ] && return 0
      fail "$key is required when ALIPAY_SIGN_MODE=cert"
    fi
    case "$value" in
      /app/alipay-cert/*)
        ;;
      *)
        fail "$key must be under /app/alipay-cert"
        ;;
    esac
    case "$value" in
      *'/../'*|*'/./'*|*/..|*/.) fail "$key contains a non-canonical path segment" ;;
    esac
    relative_path="${value#/app/alipay-cert/}"
    [ -n "$relative_path" ] || fail "$key must name a certificate file"
    [ -f "$ALIPAY_CERT_HOST_DIR/$relative_path" ] || fail "$key does not map to an existing mounted certificate file"
  elif [ "$required" = "true" ]; then
    fail "$key is required when ALIPAY_SIGN_MODE=cert"
  fi
}

assert_private_file .env
assert_private_file .env.dashboard

[ "${DEPLOY_ENV:-production}" = "production" ] || fail "DEPLOY_ENV must be production"
[ "${REGISTRY_HOST:-registry.cn-hongkong.aliyuncs.com}" = "registry.cn-hongkong.aliyuncs.com" ] || \
  fail "REGISTRY_HOST must remain registry.cn-hongkong.aliyuncs.com"
[[ "${DASHBOARD_IMAGE_TAG:-}" =~ ^dashboard-[0-9a-f]{40}$ ]] || \
  fail "DASHBOARD_IMAGE_TAG must be exactly dashboard-<40 lowercase hex SHA>; latest is forbidden"
[[ "${DASHBOARD_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  fail "DASHBOARD_IMAGE_DIGEST must be an exact sha256 registry manifest digest"

DASHBOARD_PORT="${DASHBOARD_PORT:-9821}"
[[ "$DASHBOARD_PORT" =~ ^[0-9]+$ ]] || fail "DASHBOARD_PORT must be numeric"
[ "$DASHBOARD_PORT" = "9821" ] || fail "DASHBOARD_PORT must remain 9821 because nginx routing is pinned to it"

: "${ALIPAY_CERT_HOST_DIR:?ALIPAY_CERT_HOST_DIR must be supplied by the deployment environment}"
[ -d "$ALIPAY_CERT_HOST_DIR" ] || fail "Alipay certificate directory is missing: $ALIPAY_CERT_HOST_DIR"

if ! keys="$(manifest_keys .env.dashboard)"; then
  fail ".env.dashboard contains malformed or duplicate assignments"
fi
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    DATABASE_URL|BETTER_AUTH_SECRET|BETTER_AUTH_URL|BASE_URL|AUTH_COOKIE_DOMAIN|BETTER_AUTH_TRUSTED_ORIGINS|PASSKEY_ORIGINS|API_URL|GITHUB_CLIENT_ID|GITHUB_CLIENT_SECRET|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|STRIPE_SECRET_KEY|PAYMENT_WEBHOOK_BASE_URL|ALIPAY_APP_ID|ALIPAY_APP_PRIVATE_KEY|ALIPAY_PUBLIC_KEY|ALIPAY_SIGN_MODE|ALIPAY_APP_CERT_PATH|ALIPAY_PUBLIC_CERT_PATH|ALIPAY_ROOT_CERT_PATH|HMZF_ENABLED|HMZF_GATEWAY_URL|HMZF_MCH_NO|HMZF_APP_ID|HMZF_APP_KEY|NEXT_PUBLIC_POSTHOG_KEY|NEXT_PUBLIC_POSTHOG_HOST|NEXT_PUBLIC_GOOGLE_ANALYTICS_ID|NEXT_PUBLIC_SENTRY_DSN|NEXT_PUBLIC_SENTRY_TRACES_SAMPLE_RATE|SENTRY_DSN|SENTRY_TRACES_SAMPLE_RATE|SENTRY_ORG|SENTRY_PROJECT|SENTRY_URL|SENTRY_RELEASE)
      ;;
    *)
      fail ".env.dashboard contains forbidden/unknown key: $key"
      ;;
  esac
done <<< "$keys"

require_value .env.dashboard DATABASE_URL
require_value .env.dashboard BETTER_AUTH_SECRET
require_value .env.dashboard GITHUB_CLIENT_ID
require_value .env.dashboard GITHUB_CLIENT_SECRET
require_value .env.dashboard GOOGLE_CLIENT_ID
require_value .env.dashboard GOOGLE_CLIENT_SECRET
require_value .env.dashboard STRIPE_SECRET_KEY
require_value .env.dashboard ALIPAY_APP_ID
require_value .env.dashboard ALIPAY_APP_PRIVATE_KEY
require_exact_value .env.dashboard BASE_URL https://dashboard.leaper.one
require_exact_value .env.dashboard BETTER_AUTH_URL https://dashboard.leaper.one
require_exact_value .env.dashboard API_URL https://api.leaper.one
require_exact_value .env.dashboard PAYMENT_WEBHOOK_BASE_URL https://api.leaper.one
require_exact_value .env.dashboard AUTH_COOKIE_DOMAIN ""
require_sentry_manifest .env.dashboard leaperone-dashboard

stripe_secret_key="$(dotenv_value .env.dashboard STRIPE_SECRET_KEY)"
case "$stripe_secret_key" in
  sk_test_*) fail "STRIPE_SECRET_KEY must not use a Stripe test key in production" ;;
esac

if ! alipay_sign_mode="$(dotenv_value .env.dashboard ALIPAY_SIGN_MODE)"; then
  fail ".env.dashboard must contain exactly one valid ALIPAY_SIGN_MODE assignment (key or cert)"
fi
[ "$alipay_sign_mode" = "key" ] || [ "$alipay_sign_mode" = "cert" ] || fail "ALIPAY_SIGN_MODE must be key or cert"
cert_required=false
[ "$alipay_sign_mode" = "cert" ] && cert_required=true
assert_cert_path ALIPAY_APP_CERT_PATH "$cert_required"
assert_cert_path ALIPAY_PUBLIC_CERT_PATH "$cert_required"
assert_cert_path ALIPAY_ROOT_CERT_PATH "$cert_required"

if [ "$alipay_sign_mode" = "key" ]; then
  require_value .env.dashboard ALIPAY_PUBLIC_KEY
fi

if ! hmzf_enabled="$(dotenv_value .env.dashboard HMZF_ENABLED)"; then
  fail ".env.dashboard requires HMZF_ENABLED=true or false"
fi
case "$hmzf_enabled" in
  true)
    require_value .env.dashboard HMZF_GATEWAY_URL
    require_value .env.dashboard HMZF_MCH_NO
    require_value .env.dashboard HMZF_APP_ID
    require_value .env.dashboard HMZF_APP_KEY
    ;;
  false)
    ;;
  *)
    fail "HMZF_ENABLED must be exactly true or false"
    ;;
esac

docker network inspect leaperone-prod >/dev/null 2>&1 || fail "Docker network leaperone-prod is missing"

EXPECTED_CONTAINER="leaperone-dashboard-production"
while IFS= read -r owner; do
  [ -z "$owner" ] && continue
  [ "$owner" = "$EXPECTED_CONTAINER" ] || fail "port $DASHBOARD_PORT is already published by container $owner"
done < <(docker ps --filter "publish=$DASHBOARD_PORT" --format '{{.Names}}')

if command -v ss >/dev/null 2>&1 \
  && ss -H -ltn "sport = :$DASHBOARD_PORT" | grep -q . \
  && ! docker ps --filter "name=^/${EXPECTED_CONTAINER}$" --filter "publish=$DASHBOARD_PORT" --format '{{.Names}}' | grep -qx "$EXPECTED_CONTAINER"; then
  fail "127.0.0.1:$DASHBOARD_PORT is already in use outside the expected container"
fi

docker compose config --quiet
echo "Dashboard preflight passed: ${DASHBOARD_IMAGE_TAG} -> 127.0.0.1:${DASHBOARD_PORT}"
