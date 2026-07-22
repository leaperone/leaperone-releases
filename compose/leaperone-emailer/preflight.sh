#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR=/home/leaperone/services/leaperone-emailer
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
api_image_tag="$(require_env "$COMPOSE_ENV" API_IMAGE_TAG)"
[[ "$api_image_tag" =~ ^api-[0-9a-f]{40}$ ]] || \
  fail "API_IMAGE_TAG must be exactly api-<40 lowercase hex source SHA>"

[ "$(require_env "$WORKER_ENV" DENO_ENV)" = production ] || \
  fail "DENO_ENV must be production"
[ "$(require_env "$WORKER_ENV" EMAIL_LISTENER_HOSTNAME)" = 0.0.0.0 ] || \
  fail "EMAIL_LISTENER_HOSTNAME must be 0.0.0.0"
[ "$(require_uint_range "$WORKER_ENV" EMAIL_LISTENER_PORT 25 25)" = 25 ]
require_uint_range "$WORKER_ENV" EMAIL_MAX_MESSAGE_BYTES 29360128 67108864 >/dev/null
idle_timeout_ms="$(require_uint_range "$WORKER_ENV" EMAIL_IDLE_TIMEOUT_MS 5000 300000)"
session_timeout_ms="$(require_uint_range "$WORKER_ENV" EMAIL_SESSION_TIMEOUT_MS 30000 1800000)"
require_uint_range "$WORKER_ENV" EMAIL_MAX_CONNECTIONS 1 256 >/dev/null
require_uint_range "$WORKER_ENV" EMAIL_MAX_COMMAND_BYTES 1024 65536 >/dev/null
require_uint_range "$WORKER_ENV" EMAIL_MAX_RECIPIENTS 1 64 >/dev/null
(( session_timeout_ms >= idle_timeout_ms )) || \
  fail "EMAIL_SESSION_TIMEOUT_MS must be greater than or equal to EMAIL_IDLE_TIMEOUT_MS"
[ "$(require_env "$WORKER_ENV" EMAIL_LOG_ENABLED)" = false ] || \
  fail "EMAIL_LOG_ENABLED must be false for the database-independent HK worker"
twosomeone_base_url="$(require_env "$WORKER_ENV" TWOSOMEONE_BASE_URL)"
[[ "$twosomeone_base_url" =~ ^https://[^[:space:]]+$ ]] || \
  fail "TWOSOMEONE_BASE_URL must be an HTTPS URL"
internal_secret="$(require_env "$WORKER_ENV" TWOSOMEONE_INTERNAL_SECRET)"
[ "$internal_secret" != 2someone ] || \
  fail "TWOSOMEONE_INTERNAL_SECRET must not use the handler's insecure fallback"

if awk -F= '/^DATABASE_URL=/{found=1} END{exit !found}' "$WORKER_ENV"; then
  fail "DATABASE_URL must not be injected into the database-independent HK worker"
fi

container_name="leaperone-emailer-$deploy_env"
if port_25_is_listening; then
  docker ps --format '{{.Names}}' | grep -Fxq "$container_name" || \
    fail "host TCP port 25 is already occupied by a process other than $container_name"
fi

docker compose --project-directory "$SCRIPT_DIR" -f "$COMPOSE_FILE" config --quiet
printf 'LEAPERone Email Worker preflight passed: %s -> 0.0.0.0:25\n' "$api_image_tag"
