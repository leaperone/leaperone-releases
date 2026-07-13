#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINAL="$ROOT/ops/leaperone-frontend/cutover/leaperone-local.conf"
HEADERS="$ROOT/ops/leaperone-frontend/cutover/leaperone-proxy-headers.conf"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || {
    echo "ERROR: missing final routing contract in $file: $text" >&2
    exit 1
  }
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    echo "ERROR: forbidden compatibility routing in $file: $text" >&2
    exit 1
  fi
}

require_text "$FINAL" "server_name leaper.one www.leaper.one;"
require_text "$FINAL" "proxy_pass http://127.0.0.1:9820;"
require_text "$FINAL" "server_name dashboard.leaper.one;"
require_text "$FINAL" "proxy_pass http://127.0.0.1:9821;"
require_text "$FINAL" "server_name api.leaper.one;"
require_text "$FINAL" "proxy_pass http://127.0.0.1:9801;"

# Only the two exact provider callbacks remain on the root host. They protect
# already-created payment state without retaining a general compatibility API.
require_text "$FINAL" "location = /api/recharge/notify/stripe {"
require_text "$FINAL" "proxy_pass http://127.0.0.1:9801/webhooks/payments/stripe;"
require_text "$FINAL" "location = /api/recharge/notify/alipay {"
require_text "$FINAL" "proxy_pass http://127.0.0.1:9801/webhooks/payments/alipay;"

for forbidden in \
  "next.leaper.one" \
  "127.0.0.1:9800" \
  "/api/v1/cli" \
  "/api/v1/envx" \
  "location = /api/auth" \
  "location ^~ /api/auth/" \
  "location = /api/device" \
  "location ^~ /api/device/" \
  "dashboard.leaper.one\$request_uri" \
  "@legacy_cli_issue"; do
  reject_text "$FINAL" "$forbidden"
done

if find "$ROOT/compose" "$ROOT/ops/leaperone-frontend" -type f \
  \( -iname '*candidate*' -o -iname '*cutover-local*' \) -print | grep -q .; then
  echo "ERROR: candidate or staged-cutover routing files still exist" >&2
  exit 1
fi

reject_text "$HEADERS" 'proxy_set_header Host $http_host;'

echo "Final one-shot routing contracts passed"
