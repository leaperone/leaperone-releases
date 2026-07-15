#!/bin/bash
# Fail-closed NIMEI Germany origin and runtime-secret preflight. Secret values
# are never printed; cross-app relationships are compared by SHA-256 only.
set -euo pipefail

PROJECT_DIR=/opt/apps/nimei/production
NIMEI_ENV="$PROJECT_DIR/.env"
DOKI_ENV=/opt/apps/dokilove/production/.env
ACTIVE_CONF=/etc/nginx/sites-enabled/nimei-local.conf
CERT=/etc/nginx/ssl/nimei.app/fullchain.cer
KEY=/etc/nginx/ssl/nimei.app/nimei.app.key

read_env_value() {
  local file="$1"
  local key="$2"
  local value
  value="$(awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      sub("^[^=]*=", "")
      sub("\\r$", "")
      print
      exit
    }
  ' "$file")"
  if [ "${#value}" -ge 2 ]; then
    if [[ "$value" == \"*\" && "$value" == *\" ]] || \
       [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

require_env() {
  local file="$1"
  local key="$2"
  local value
  value="$(read_env_value "$file" "$key")"
  [ -n "$value" ] || {
    echo "ERROR: required $key is missing/empty in $file" >&2
    exit 1
  }
  printf '%s' "$value"
}

value_hash() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

csv_contains() {
  local csv="$1"
  local wanted="$2"
  local item
  IFS=',' read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ "$item" = "$wanted" ] && return 0
  done
  return 1
}

test -d "$PROJECT_DIR" || { echo "ERROR: $PROJECT_DIR is missing" >&2; exit 1; }
test -s "$NIMEI_ENV" || { echo "ERROR: $NIMEI_ENV is missing or empty" >&2; exit 1; }
test -s "$DOKI_ENV" || { echo "ERROR: $DOKI_ENV is missing or empty" >&2; exit 1; }
case "$(stat -c '%a' "$NIMEI_ENV")" in
  400|600) ;;
  *) echo "ERROR: $NIMEI_ENV must be mode 400 or 600" >&2; exit 1 ;;
esac

nimei_database="$(require_env "$NIMEI_ENV" DATABASE_URL)"
doki_database="$(require_env "$DOKI_ENV" DATABASE_URL)"
[[ "$nimei_database" =~ ^postgres(ql)?://.+/dokilove_db([?].*)?$ ]] || {
  echo "ERROR: NIMEI DATABASE_URL must target dokilove_db" >&2
  exit 1
}
[ "$(value_hash "$nimei_database")" = "$(value_hash "$doki_database")" ] || {
  echo "ERROR: NIMEI and DokiLove DATABASE_URL values differ" >&2
  exit 1
}

nimei_auth="$(require_env "$NIMEI_ENV" AUTH_SECRET)"
nimei_better_auth="$(require_env "$NIMEI_ENV" BETTER_AUTH_SECRET)"
[ "${#nimei_auth}" -ge 32 ] || { echo "ERROR: NIMEI AUTH_SECRET is shorter than 32 characters" >&2; exit 1; }
[ "$nimei_auth" = "$nimei_better_auth" ] || {
  echo "ERROR: NIMEI AUTH_SECRET and BETTER_AUTH_SECRET must be identical" >&2
  exit 1
}
doki_auth="$(require_env "$DOKI_ENV" AUTH_SECRET)"
doki_better_auth="$(require_env "$DOKI_ENV" BETTER_AUTH_SECRET)"
if [ "$(value_hash "$nimei_auth")" = "$(value_hash "$doki_auth")" ] || \
   [ "$(value_hash "$nimei_auth")" = "$(value_hash "$doki_better_auth")" ]; then
  echo "ERROR: NIMEI auth secret must be independent from DokiLove" >&2
  exit 1
fi

[ "$(require_env "$NIMEI_ENV" BETTER_AUTH_URL)" = "https://nimei.app" ] || {
  echo "ERROR: NIMEI BETTER_AUTH_URL must be https://nimei.app" >&2
  exit 1
}
trusted_origins="$(require_env "$NIMEI_ENV" TRUSTED_ORIGINS)"
csv_contains "$trusted_origins" https://nimei.app || {
  echo "ERROR: TRUSTED_ORIGINS must include https://nimei.app" >&2
  exit 1
}
csv_contains "$trusted_origins" https://www.nimei.app || {
  echo "ERROR: TRUSTED_ORIGINS must include https://www.nimei.app" >&2
  exit 1
}
[ "$(require_env "$NIMEI_ENV" TRUSTED_PROXY)" = "1" ] || {
  echo "ERROR: NIMEI TRUSTED_PROXY must be 1 behind the controlled Germany Nginx/Cloudflare chain" >&2
  exit 1
}

nimei_encryption="$(require_env "$NIMEI_ENV" ENCRYPTION_KEY)"
doki_encryption="$(require_env "$DOKI_ENV" ENCRYPTION_KEY)"
[ "$(value_hash "$nimei_encryption")" = "$(value_hash "$doki_encryption")" ] || {
  echo "ERROR: NIMEI ENCRYPTION_KEY must match DokiLove for migrated BYOK ciphertext" >&2
  exit 1
}
decoded_key_bytes="$(printf '%s' "$nimei_encryption" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')"
[ "$decoded_key_bytes" = "32" ] || {
  echo "ERROR: ENCRYPTION_KEY must decode to exactly 32 bytes" >&2
  exit 1
}

require_env "$NIMEI_ENV" RESEND_API_KEY >/dev/null
require_env "$NIMEI_ENV" RESEND_FROM >/dev/null
nimei_sentry_dsn="$(require_env "$NIMEI_ENV" SENTRY_DSN)"
doki_sentry_dsn="$(require_env "$DOKI_ENV" SENTRY_DSN)"
[ "$(value_hash "$nimei_sentry_dsn")" = "$(value_hash "$doki_sentry_dsn")" ] || {
  echo "ERROR: NIMEI SENTRY_DSN must match DokiLove" >&2
  exit 1
}
[ "$(require_env "$NIMEI_ENV" SENTRY_ENVIRONMENT)" = "production" ] || {
  echo "ERROR: NIMEI SENTRY_ENVIRONMENT must be production" >&2
  exit 1
}
[ "$(require_env "$NIMEI_ENV" OSS_REQUIRE_HOT_STORAGE)" = "true" ] || {
  echo "ERROR: OSS_REQUIRE_HOT_STORAGE must be true" >&2
  exit 1
}
for key_name in OSS_HOT_ENDPOINT OSS_HOT_KEY_ID OSS_HOT_SECRET OSS_HOT_BUCKET OSS_HOT_REGION OSS_PUBLIC_BASE_URL; do
  nimei_value="$(require_env "$NIMEI_ENV" "$key_name")"
  doki_value="$(require_env "$DOKI_ENV" "$key_name")"
  [ "$(value_hash "$nimei_value")" = "$(value_hash "$doki_value")" ] || {
    echo "ERROR: NIMEI $key_name must match DokiLove" >&2
    exit 1
  }
done

test -s "$CERT" || { echo "ERROR: NIMEI TLS certificate is missing" >&2; exit 1; }
test -s "$KEY" || { echo "ERROR: NIMEI TLS private key is missing" >&2; exit 1; }
openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || {
  echo "ERROR: NIMEI TLS certificate is expired or expires within 24 hours" >&2
  exit 1
}
openssl x509 -in "$CERT" -noout -checkhost nimei.app >/dev/null
openssl x509 -in "$CERT" -noout -checkhost www.nimei.app >/dev/null
cert_pubkey="$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"
key_pubkey="$(openssl pkey -in "$KEY" -pubout -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"
[ "$cert_pubkey" = "$key_pubkey" ] || { echo "ERROR: NIMEI certificate/private key mismatch" >&2; exit 1; }

test -s "$ACTIVE_CONF" || {
  echo "ERROR: $ACTIVE_CONF is missing; run install-nginx.sh before deployment" >&2
  exit 1
}
grep -qE 'upstream[[:space:]]+nimei_web_active' "$ACTIVE_CONF" || {
  echo "ERROR: $ACTIVE_CONF has no nimei_web_active upstream" >&2
  exit 1
}
grep -qE 'server[[:space:]]+127\.0\.0\.1:(9811|9812)' "$ACTIVE_CONF" || {
  echo "ERROR: NIMEI active upstream is not 9811/9812" >&2
  exit 1
}
grep -qF 'return 301 https://nimei.app$request_uri;' "$ACTIVE_CONF" || {
  echo "ERROR: NIMEI canonical HTTP/www redirect is missing" >&2
  exit 1
}
grep -qE 'proxy_pass[[:space:]]+http://nimei_web_active' "$ACTIVE_CONF" || {
  echo "ERROR: $ACTIVE_CONF does not route to nimei_web_active" >&2
  exit 1
}
nginx -t >/dev/null
docker network inspect leaperone-prod >/dev/null
docker compose -f "$PROJECT_DIR/docker-compose.yml" config --quiet
echo "NIMEI origin/runtime-secret preflight passed"
