#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANDIDATE="$ROOT/compose/leaperone-www/nginx/leaperone-candidate-local.conf"
CUTOVER="$ROOT/compose/leaperone-www/nginx/leaperone-cutover-local.conf"
HEADERS="$ROOT/compose/leaperone-www/nginx/leaperone-proxy-headers.conf"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || {
    echo "ERROR: missing routing contract in $file: $text" >&2
    exit 1
  }
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    echo "ERROR: forbidden routing contract in $file: $text" >&2
    exit 1
  fi
}

# Candidate mode must leave the root on legacy while exposing real candidate
# hostnames for browser/OAuth/Passkey validation.
require_text "$CANDIDATE" "server_name leaper.one www.leaper.one;"
require_text "$CANDIDATE" "proxy_pass http://127.0.0.1:9800;"
require_text "$CANDIDATE" "server_name next.leaper.one;"
require_text "$CANDIDATE" "proxy_pass http://127.0.0.1:9820;"
require_text "$CANDIDATE" "server_name dashboard.leaper.one;"
require_text "$CANDIDATE" "proxy_pass http://127.0.0.1:9821;"
require_text "$CANDIDATE" "server_name api.leaper.one;"
require_text "$CANDIDATE" "proxy_pass http://127.0.0.1:9801;"

# The exact exchange split must appear before the general CLI prefix.
exchange_line="$(grep -nF 'location = /api/v1/cli/auth/exchange {' "$CUTOVER" | cut -d: -f1)"
cli_line="$(grep -nF 'location ^~ /api/v1/cli/ {' "$CUTOVER" | cut -d: -f1)"
[ -n "$exchange_line" ] && [ -n "$cli_line" ] && [ "$exchange_line" -lt "$cli_line" ] || {
  echo "ERROR: exact exchange routing must precede the general CLI prefix" >&2
  exit 1
}

require_text "$CUTOVER" 'if ($request_method = POST) { return 418; }'
require_text "$CUTOVER" "location @legacy_cli_issue {"
require_text "$CUTOVER" "proxy_set_header Host api.leaper.one;"
require_text "$CUTOVER" "proxy_set_header Host dashboard.leaper.one;"
require_text "$CUTOVER" 'proxy_set_header X-Forwarded-Host $host;'
require_text "$CUTOVER" 'return 302 https://dashboard.leaper.one$request_uri;'
require_text "$CUTOVER" "proxy_pass http://127.0.0.1:9801/webhooks/payments/stripe;"
require_text "$CUTOVER" "proxy_pass http://127.0.0.1:9801/webhooks/payments/alipay;"
require_text "$CUTOVER" "location ^~ /api/v1/envx/ {"
require_text "$CUTOVER" "server_name next.leaper.one;"
reject_text "$HEADERS" 'proxy_set_header Host $http_host;'

echo "Static candidate/cutover routing contracts passed"
