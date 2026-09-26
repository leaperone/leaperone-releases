#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -f .env ]] || fail ".env is required (host-managed ports only)"
set -a
# shellcheck disable=SC1091
. ./.env
set +a
[[ "${DEPLOY_ENV:-production}" == production ]] || fail "DEPLOY_ENV must be production"
for name in WWW DASHBOARD API; do
  port_var="${name}_PORT"; port="${!port_var:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || fail "$port_var must be numeric and supplied by the host"
  (( port > 1024 && port < 65536 )) || fail "$port_var must be an unprivileged loopback port"
done
[[ "$WWW_PORT" != "$DASHBOARD_PORT" && "$WWW_PORT" != "$API_PORT" && "$DASHBOARD_PORT" != "$API_PORT" ]] || fail "WWW_PORT, DASHBOARD_PORT, and API_PORT must be distinct"
for file in .env .env.www .env.dashboard .env.api; do
  [[ -f "$file" ]] || fail "$file is required"
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")"
  [[ "$mode" == 600 ]] || fail "$file must have mode 0600 (found $mode)"
done
release_sha=""
for var in WWW_IMAGE_REF DASHBOARD_IMAGE_REF API_IMAGE_REF; do
  component="$(printf '%s' "${var%_IMAGE_REF}" | tr '[:upper:]' '[:lower:]')"
  value="${!var:-}"
  [[ "$value" =~ ^registry\.cn-hongkong\.aliyuncs\.com/leaperone/undersky:${component}-([0-9a-f]{40})@sha256:[0-9a-f]{64}$ ]] || fail "$var must be the matching component's immutable image digest"
  if [[ -z "$release_sha" ]]; then release_sha="${BASH_REMATCH[1]}"; fi
  [[ "${BASH_REMATCH[1]}" == "$release_sha" ]] || fail "All components must use the same source SHA"
done
dotenv_value() {
  local file="$1" key="$2"
  awk -F= -v wanted="$key" '
    $1 == wanted {
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      if (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") value = substr(value, 2, length(value) - 2)
      if (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") value = substr(value, 2, length(value) - 2)
      print value; found++
    }
    END { if (found != 1) exit 1 }
  ' "$file"
}
api_database_url="$(dotenv_value .env.api DATABASE_URL)" || fail ".env.api must contain exactly one DATABASE_URL assignment"
dashboard_database_url="$(dotenv_value .env.dashboard DATABASE_URL)" || fail ".env.dashboard must contain exactly one DATABASE_URL assignment"
[[ "$api_database_url" == "$dashboard_database_url" ]] || fail "API and Dashboard must use the exact same DATABASE_URL"
[[ "$api_database_url" =~ ^[^:]+://[^/]+/leaperone_db([?].*)?$ ]] || fail "DATABASE_URL must target a host-backed leaperone_db database"
[[ "$(dotenv_value .env.dashboard API_URL)" == "https://api.leaper.one" ]] || fail ".env.dashboard API_URL must remain the legacy control-plane endpoint during the core rollout"
[[ "$(dotenv_value .env.www API_URL)" == "https://api.undersky.ai" ]] || fail ".env.www API_URL must be api.undersky.ai"
[[ "$(dotenv_value .env.www NEXT_PUBLIC_DASHBOARD_URL)" == "https://dashboard.undersky.ai" ]] || fail ".env.www dashboard URL must be dashboard.undersky.ai"
[[ "$(dotenv_value .env.dashboard BETTER_AUTH_URL)" == "https://dashboard.undersky.ai" ]] || fail ".env.dashboard BETTER_AUTH_URL must be dashboard.undersky.ai"
[[ "$(dotenv_value .env.dashboard BASE_URL)" == "https://dashboard.undersky.ai" ]] || fail ".env.dashboard BASE_URL must be dashboard.undersky.ai"
docker compose config --quiet
resolved_config="$(docker compose config)"
grep -Eq 'ENABLE_IMAGE_WORKER: "?false"?' <<<"$resolved_config" || fail "Compose must enforce ENABLE_IMAGE_WORKER=false"
grep -Eq 'ENABLE_VIDEO_WORKER: "?false"?' <<<"$resolved_config" || fail "Compose must enforce ENABLE_VIDEO_WORKER=false"
grep -Eq 'RUN_MIGRATIONS: "?false"?' <<<"$resolved_config" || fail "Compose must enforce RUN_MIGRATIONS=false"
grep -Eq 'LEAPERONE_LEGACY_DATABASE: "?true"?' <<<"$resolved_config" || fail "Compose must enforce LEAPERONE_LEGACY_DATABASE=true"
echo "UnderSky core preflight passed (immutable images, leaperone_db, no migrations, workers disabled)"
