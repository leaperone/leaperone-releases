#!/bin/bash
# One-time Germany origin bootstrap. Certificate issuance is intentionally kept
# outside this script; it must already exist before Nginx can be enabled.
set -euo pipefail

PROJECT_DIR=/opt/apps/nimei/production
SOURCE="$PROJECT_DIR/nginx/nimei-local.conf"
TARGET=/etc/nginx/sites-enabled/nimei-local.conf

test -s "$SOURCE" || { echo "ERROR: $SOURCE missing" >&2; exit 1; }
test -s /etc/nginx/ssl/nimei.app/fullchain.cer || { echo "ERROR: NIMEI certificate missing" >&2; exit 1; }
test -s /etc/nginx/ssl/nimei.app/nimei.app.key || { echo "ERROR: NIMEI private key missing" >&2; exit 1; }

if [ -e "$TARGET" ]; then
  echo "ERROR: $TARGET already exists; refusing to overwrite the active upstream" >&2
  exit 1
fi

install -m 0644 "$SOURCE" "$TARGET"
if ! nginx -t; then
  rm -f "$TARGET"
  exit 1
fi
nginx -s reload
echo "Installed $TARGET (bootstrap upstream 127.0.0.1:9811)"

