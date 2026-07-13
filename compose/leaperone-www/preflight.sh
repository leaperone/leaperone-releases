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
  [ -f "$path" ] || fail "$path is missing"
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
  [ "$mode" = "600" ] || fail "$path must have mode 0600 (found $mode)"
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

assert_private_file .env
assert_private_file .env.www

[ "${DEPLOY_ENV:-production}" = "production" ] || fail "DEPLOY_ENV must be production"
[ "${REGISTRY_HOST:-registry.cn-hongkong.aliyuncs.com}" = "registry.cn-hongkong.aliyuncs.com" ] || \
  fail "REGISTRY_HOST must remain registry.cn-hongkong.aliyuncs.com"
[[ "${WWW_IMAGE_TAG:-}" =~ ^www-[0-9a-f]{40}$ ]] || \
  fail "WWW_IMAGE_TAG must be exactly www-<40 lowercase hex SHA>; latest is forbidden"
[[ "${WWW_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  fail "WWW_IMAGE_DIGEST must be an exact sha256 registry manifest digest"

WWW_PORT="${WWW_PORT:-9820}"
[[ "$WWW_PORT" =~ ^[0-9]+$ ]] || fail "WWW_PORT must be numeric"
[ "$WWW_PORT" = "9820" ] || fail "WWW_PORT must remain 9820 because nginx routing is pinned to it"

case "${NGINX_ROUTING_MODE:-off}" in
  off|candidate|cutover) ;;
  *) fail "NGINX_ROUTING_MODE must be off, candidate, or cutover" ;;
esac

if ! keys="$(manifest_keys .env.www)"; then
  fail ".env.www contains malformed or duplicate assignments"
fi
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    API_URL|NEXT_PUBLIC_DASHBOARD_URL|NEXT_PUBLIC_POSTHOG_KEY|NEXT_PUBLIC_POSTHOG_HOST|NEXT_PUBLIC_GOOGLE_ANALYTICS_ID|NEXT_PUBLIC_SENTRY_DSN|NEXT_PUBLIC_SENTRY_TRACES_SAMPLE_RATE|SENTRY_DSN|SENTRY_TRACES_SAMPLE_RATE|SENTRY_ORG|SENTRY_PROJECT|SENTRY_URL|SENTRY_RELEASE)
      ;;
    *)
      fail ".env.www contains forbidden/unknown key: $key"
      ;;
  esac
done <<< "$keys"

require_exact_value .env.www API_URL https://api.leaper.one
require_exact_value .env.www NEXT_PUBLIC_DASHBOARD_URL https://dashboard.leaper.one
require_sentry_manifest .env.www leaperone-www

docker network inspect leaperone-prod >/dev/null 2>&1 || fail "Docker network leaperone-prod is missing"

EXPECTED_CONTAINER="leaperone-www-production"
while IFS= read -r owner; do
  [ -z "$owner" ] && continue
  [ "$owner" = "$EXPECTED_CONTAINER" ] || fail "port $WWW_PORT is already published by container $owner"
done < <(docker ps --filter "publish=$WWW_PORT" --format '{{.Names}}')

if command -v ss >/dev/null 2>&1 \
  && ss -H -ltn "sport = :$WWW_PORT" | grep -q . \
  && ! docker ps --filter "name=^/${EXPECTED_CONTAINER}$" --filter "publish=$WWW_PORT" --format '{{.Names}}' | grep -qx "$EXPECTED_CONTAINER"; then
  fail "127.0.0.1:$WWW_PORT is already in use outside the expected container"
fi

docker compose config --quiet
echo "WWW preflight passed: ${WWW_IMAGE_TAG} -> 127.0.0.1:${WWW_PORT}"
