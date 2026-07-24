#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

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
  [[ "$public_dsn" =~ ^https://[A-Za-z0-9._-]+@s\.leaper\.one/[0-9]+$ ]] || \
    fail "Sentry DSN must use the LEAPERone product ingest domain"

  if ! project="$(dotenv_value "$file" SENTRY_PROJECT)"; then
    fail "$file requires SENTRY_PROJECT"
  fi
  [ "$project" = leaperone-www ] || fail "SENTRY_PROJECT must equal leaperone-www"
}

assert_private_file .env
assert_private_file .env.www

if ! root_keys="$(manifest_keys .env)"; then
  fail ".env contains malformed or duplicate assignments"
fi
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    DEPLOY_ENV|REGISTRY_HOST|WWW_CN_PORT|WWW_CN_CONTAINER_NAME|DEPLOY_STATE_ROOT)
      ;;
    *)
      fail ".env contains forbidden/unknown key: $key"
      ;;
  esac
done <<< "$root_keys"
require_exact_value .env DEPLOY_ENV production
require_exact_value .env REGISTRY_HOST registry.cn-hongkong.aliyuncs.com
require_exact_value .env DEPLOY_STATE_ROOT "${DEPLOY_STATE_ROOT:?DEPLOY_STATE_ROOT is required}"

[ "${DEPLOY_ENV:-production}" = production ] || fail "DEPLOY_ENV must be production"
[ "${REGISTRY_HOST:-registry.cn-hongkong.aliyuncs.com}" = registry.cn-hongkong.aliyuncs.com ] || \
  fail "REGISTRY_HOST must remain registry.cn-hongkong.aliyuncs.com"
[[ "${WWW_CN_SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || \
  fail "WWW_CN_SOURCE_SHA must be a full lowercase Git SHA"
[ "${WWW_CN_IMAGE_TAG:-}" = "www-cn-${WWW_CN_SOURCE_SHA}" ] || \
  fail "WWW_CN_IMAGE_TAG must equal www-cn-<WWW_CN_SOURCE_SHA>; latest is forbidden"
[[ "${WWW_CN_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  fail "WWW_CN_IMAGE_DIGEST must be an exact sha256 registry manifest digest"
[ "${IMAGE_REF:-}" = "registry.cn-hongkong.aliyuncs.com/leaperone/leaperone:${WWW_CN_IMAGE_TAG}" ] || \
  fail "IMAGE_REF must match the immutable WWW_CN_IMAGE_TAG"
[[ "${RELEASES_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || \
  fail "RELEASES_SHA must be a full lowercase release-repository SHA"

WWW_CN_PORT="$(dotenv_value .env WWW_CN_PORT)" || fail ".env requires WWW_CN_PORT"
[[ "$WWW_CN_PORT" =~ ^[0-9]+$ ]] || fail "WWW_CN_PORT must be numeric"
(( WWW_CN_PORT >= 1024 && WWW_CN_PORT <= 65535 )) || fail "WWW_CN_PORT must be between 1024 and 65535"

WWW_CN_CONTAINER_NAME="$(dotenv_value .env WWW_CN_CONTAINER_NAME)" || \
  fail ".env requires WWW_CN_CONTAINER_NAME"
[[ "$WWW_CN_CONTAINER_NAME" =~ ^[a-z0-9][a-z0-9_.-]+$ ]] || \
  fail "WWW_CN_CONTAINER_NAME is invalid"

if ! keys="$(manifest_keys .env.www)"; then
  fail ".env.www contains malformed or duplicate assignments"
fi
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    API_URL|NEXT_PUBLIC_DASHBOARD_URL|NEXT_PUBLIC_POSTHOG_KEY|NEXT_PUBLIC_POSTHOG_HOST|NEXT_PUBLIC_GOOGLE_ANALYTICS_ID|NEXT_PUBLIC_SENTRY_DSN|NEXT_PUBLIC_SENTRY_TRACES_SAMPLE_RATE|SENTRY_DSN|SENTRY_TRACES_SAMPLE_RATE|SENTRY_ORG|SENTRY_PROJECT|SENTRY_URL)
      ;;
    *)
      fail ".env.www contains forbidden/unknown key: $key"
      ;;
  esac
done <<< "$keys"

require_exact_value .env.www API_URL https://api.leaper.one
require_exact_value .env.www NEXT_PUBLIC_DASHBOARD_URL https://dashboard.leaper.one
require_sentry_manifest .env.www

EXPECTED_CONTAINER="$WWW_CN_CONTAINER_NAME"
while IFS= read -r owner; do
  [ -z "$owner" ] && continue
  [ "$owner" = "$EXPECTED_CONTAINER" ] || fail "port $WWW_CN_PORT is already published by container $owner"
done < <(docker ps --filter "publish=$WWW_CN_PORT" --format '{{.Names}}')

if command -v ss >/dev/null 2>&1 \
  && ss -H -ltn "sport = :$WWW_CN_PORT" | grep -q . \
  && ! docker ps --filter "name=^/${EXPECTED_CONTAINER}$" --filter "publish=$WWW_CN_PORT" --format '{{.Names}}' | grep -qx "$EXPECTED_CONTAINER"; then
  fail "127.0.0.1:$WWW_CN_PORT is already in use outside the expected container"
fi

docker compose config --quiet
echo "LEAPERone CN preflight passed: ${WWW_CN_IMAGE_TAG}@${WWW_CN_IMAGE_DIGEST} -> 127.0.0.1:${WWW_CN_PORT}"
