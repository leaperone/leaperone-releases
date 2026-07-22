#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR=/home/leaperone/services/leaperone-email-worker
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_ENV="$SCRIPT_DIR/.env"
WORKER_ENV="$SCRIPT_DIR/.env.worker"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

read_env_value() {
  local file="$1" key="$2" value
  value="$(awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      sub("^[^=]*=", "")
      sub("\\r$", "")
      print
      exit
    }
  ' "$file")"
  if [ "${#value}" -ge 2 ] && {
    [[ "$value" == \"* && "$value" == *\" ]] ||
      [[ "$value" == \'* && "$value" == *\' ]]
  }; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

require_env() {
  local file="$1" key="$2" value
  value="$(read_env_value "$file" "$key")"
  [ -n "$value" ] || fail "$key is missing or empty in $file"
  printf '%s' "$value"
}

require_uint_range() {
  local file="$1" key="$2" minimum="$3" maximum="$4" value numeric
  value="$(require_env "$file" "$key")"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$key must be an unsigned integer"
  [ "${#value}" -le 10 ] || fail "$key is outside the supported range"
  numeric=$((10#$value))
  (( numeric >= minimum && numeric <= maximum )) || \
    fail "$key must be between $minimum and $maximum (found $value)"
  printf '%s' "$numeric"
}

assert_env_file() {
  local file="$1" mode duplicates
  [ -s "$file" ] || fail "$file is missing or empty"
  mode="$(stat -c '%a' "$file")"
  case "$mode" in
    400|600) ;;
    *) fail "$file must have mode 0400 or 0600 (found $mode)" ;;
  esac
  duplicates="$(awk -F= '
    /^[A-Za-z_][A-Za-z0-9_]*=/ { count[$1]++ }
    END { for (key in count) if (count[key] > 1) print key }
  ' "$file")"
  [ -z "$duplicates" ] || fail "$file contains duplicate keys"
}

port_25_is_listening() {
  if command -v ss >/dev/null; then
    ss -H -ltn 'sport = :25' | grep -q .
    return
  fi
  if command -v netstat >/dev/null; then
    netstat -ltn 2>/dev/null | awk '$4 ~ /:25$/ { found=1 } END { exit !found }'
    return
  fi
  fail "ss or netstat is required to verify TCP port 25"
}

[ "$SCRIPT_DIR" = "$EXPECTED_DIR" ] || \
  fail "run the production preflight from $EXPECTED_DIR (current: $SCRIPT_DIR)"
[ -f "$COMPOSE_FILE" ] || fail "$COMPOSE_FILE is missing"
command -v docker >/dev/null || fail "docker is unavailable"
docker info >/dev/null 2>&1 || fail "docker daemon is unavailable to the current user"
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is unavailable"

assert_env_file "$COMPOSE_ENV"
assert_env_file "$WORKER_ENV"

deploy_env="$(require_env "$COMPOSE_ENV" DEPLOY_ENV)"
[ "$deploy_env" = production ] || fail "DEPLOY_ENV must be production"
registry_host="$(require_env "$COMPOSE_ENV" REGISTRY_HOST)"
[ "$registry_host" = registry.cn-hongkong.aliyuncs.com ] || \
  fail "REGISTRY_HOST must remain registry.cn-hongkong.aliyuncs.com"
image_tag="$(require_env "$COMPOSE_ENV" EMAIL_WORKER_IMAGE_TAG)"
[[ "$image_tag" =~ ^email-worker-[0-9a-f]{40}$ ]] || \
  fail "EMAIL_WORKER_IMAGE_TAG must be exactly email-worker-<40 lowercase hex source SHA>"
source_sha="$(require_env "$COMPOSE_ENV" EMAIL_WORKER_SOURCE_SHA)"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || \
  fail "EMAIL_WORKER_SOURCE_SHA must be a full lowercase source SHA"
[ "$image_tag" = "email-worker-$source_sha" ] || \
  fail "EMAIL_WORKER_IMAGE_TAG does not match EMAIL_WORKER_SOURCE_SHA"
image_digest="$(require_env "$COMPOSE_ENV" EMAIL_WORKER_IMAGE_DIGEST)"
[[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  fail "EMAIL_WORKER_IMAGE_DIGEST must be a sha256 registry manifest digest"
release_tag="$(require_env "$COMPOSE_ENV" EMAIL_WORKER_RELEASE_TAG)"
[[ "$release_tag" =~ ^email-worker-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
  fail "EMAIL_WORKER_RELEASE_TAG must be email-worker-vX.Y.Z"
releases_sha="$(require_env "$COMPOSE_ENV" RELEASES_SHA)"
[[ "$releases_sha" =~ ^[0-9a-f]{40}$ ]] || \
  fail "RELEASES_SHA must be a full lowercase releases repository SHA"

[ "$(require_env "$WORKER_ENV" EMAIL_WORKER_ENVIRONMENT)" = production ] || \
  fail "EMAIL_WORKER_ENVIRONMENT must be production"
[ "$(require_env "$WORKER_ENV" EMAIL_LISTENER_HOSTNAME)" = 0.0.0.0 ] || \
  fail "EMAIL_LISTENER_HOSTNAME must be 0.0.0.0"
[ "$(require_uint_range "$WORKER_ENV" EMAIL_LISTENER_PORT 2525 2525)" = 2525 ]
require_uint_range "$WORKER_ENV" EMAIL_MAX_MESSAGE_BYTES 29360128 67108864 >/dev/null
idle_timeout_ms="$(require_uint_range "$WORKER_ENV" EMAIL_IDLE_TIMEOUT_MS 5000 300000)"
session_timeout_ms="$(require_uint_range "$WORKER_ENV" EMAIL_SESSION_TIMEOUT_MS 30000 1800000)"
require_uint_range "$WORKER_ENV" EMAIL_MAX_CONNECTIONS 1 8 >/dev/null
require_uint_range "$WORKER_ENV" EMAIL_MAX_COMMAND_BYTES 1024 65536 >/dev/null
require_uint_range "$WORKER_ENV" EMAIL_MAX_RECIPIENTS 1 64 >/dev/null
(( session_timeout_ms >= idle_timeout_ms )) || \
  fail "EMAIL_SESSION_TIMEOUT_MS must be greater than or equal to EMAIL_IDLE_TIMEOUT_MS"
twosomeone_base_url="$(require_env "$WORKER_ENV" TWOSOMEONE_BASE_URL)"
[[ "$twosomeone_base_url" =~ ^https://[^[:space:]]+$ ]] || \
  fail "TWOSOMEONE_BASE_URL must be an HTTPS URL"
internal_secret="$(require_env "$WORKER_ENV" TWOSOMEONE_INTERNAL_SECRET)"
[ "$internal_secret" != 2someone ] || \
  fail "TWOSOMEONE_INTERNAL_SECRET must not use an insecure fallback"
sentry_dsn="$(read_env_value "$WORKER_ENV" SENTRY_DSN_EMAIL_WORKER)"
if [ -n "$sentry_dsn" ] && ! [[ "$sentry_dsn" =~ ^https://[^[:space:]]+$ ]]; then
  fail "SENTRY_DSN_EMAIL_WORKER must be an HTTPS DSN when configured"
fi
sentry_sample_rate="$(read_env_value "$WORKER_ENV" SENTRY_TRACES_SAMPLE_RATE_EMAIL_WORKER)"
if [ -n "$sentry_sample_rate" ] && ! awk -v value="$sentry_sample_rate" '
  BEGIN { exit !(value ~ /^(0(\.[0-9]+)?|1(\.0+)?)$/ && value >= 0 && value <= 1) }
'; then
  fail "SENTRY_TRACES_SAMPLE_RATE_EMAIL_WORKER must be between 0 and 1"
fi

for forbidden_key in DATABASE_URL DENO_ENV EMAIL_LOG_ENABLED POSTHOG_PROJECT_TOKEN SENTRY_DSN_API; do
  if awk -F= -v wanted="$forbidden_key" 'index($0,wanted "=")==1{found=1} END{exit !found}' "$WORKER_ENV"; then
    fail "$forbidden_key is not part of the standalone Email Worker runtime contract"
  fi
done

container_name="leaperone-email-worker-$deploy_env"
if port_25_is_listening; then
  docker ps --format '{{.Names}}' | grep -Fxq "$container_name" || \
    fail "host TCP port 25 is already occupied by a process other than $container_name"
fi

docker compose --project-directory "$SCRIPT_DIR" -f "$COMPOSE_FILE" config --quiet
printf 'LEAPERone Email Worker preflight passed: %s@%s -> 0.0.0.0:25\n' \
  "$image_tag" "$image_digest"
