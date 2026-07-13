#!/usr/bin/env bash
set -euo pipefail

STAMP="${1:?Usage: rollback-nginx.sh <UTC backup stamp, e.g. 20260713T120000Z>}"
if ! [[ "$STAMP" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo "ERROR: invalid backup stamp: $STAMP" >&2
  exit 1
fi

BACKUP_DIR="/etc/nginx/backups/leaperone"
TARGET_CONFIG="/etc/nginx/sites-enabled/leaperone-local.conf"
TARGET_HEADERS="/etc/nginx/snippets/leaperone-proxy-headers.conf"
CONFIG_BACKUP="${BACKUP_DIR}/leaperone-local.conf.${STAMP}"
HEADERS_BACKUP="${BACKUP_DIR}/leaperone-proxy-headers.conf.${STAMP}"
RESCUE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESCUE_CONFIG="${BACKUP_DIR}/leaperone-local.conf.pre-rollback.${RESCUE_STAMP}"
RESCUE_HEADERS="${BACKUP_DIR}/leaperone-proxy-headers.conf.pre-rollback.${RESCUE_STAMP}"

for command in flock install nginx; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $command" >&2
    exit 1
  }
done

if [ ! -f "$CONFIG_BACKUP" ] && [ ! -f "${CONFIG_BACKUP}.absent" ]; then
  echo "ERROR: no config backup or absence marker for $STAMP" >&2
  exit 1
fi
if [ ! -f "$HEADERS_BACKUP" ] && [ ! -f "${HEADERS_BACKUP}.absent" ]; then
  echo "ERROR: no headers backup or absence marker for $STAMP" >&2
  exit 1
fi

exec 9>/run/lock/leaperone-nginx-install.lock
flock -x 9
install -d -m 0755 "$BACKUP_DIR" /etc/nginx/snippets

HAD_CURRENT_CONFIG=false
HAD_CURRENT_HEADERS=false
if [ -f "$TARGET_CONFIG" ]; then
  install -m 0644 "$TARGET_CONFIG" "$RESCUE_CONFIG"
  HAD_CURRENT_CONFIG=true
fi
if [ -f "$TARGET_HEADERS" ]; then
  install -m 0644 "$TARGET_HEADERS" "$RESCUE_HEADERS"
  HAD_CURRENT_HEADERS=true
fi

restore_rescue() {
  echo "Restoring pre-rollback nginx files..." >&2
  if [ "$HAD_CURRENT_CONFIG" = true ]; then
    install -m 0644 "$RESCUE_CONFIG" "$TARGET_CONFIG"
  else
    rm -f "$TARGET_CONFIG"
  fi
  if [ "$HAD_CURRENT_HEADERS" = true ]; then
    install -m 0644 "$RESCUE_HEADERS" "$TARGET_HEADERS"
  else
    rm -f "$TARGET_HEADERS"
  fi
  nginx -t
  nginx -s reload
}

if [ -f "$CONFIG_BACKUP" ]; then
  install -m 0644 "$CONFIG_BACKUP" "$TARGET_CONFIG"
else
  rm -f "$TARGET_CONFIG"
fi
if [ -f "$HEADERS_BACKUP" ]; then
  install -m 0644 "$HEADERS_BACKUP" "$TARGET_HEADERS"
else
  rm -f "$TARGET_HEADERS"
fi

if ! nginx -t; then
  restore_rescue
  echo "ERROR: requested rollback configuration failed nginx -t" >&2
  exit 1
fi
if ! nginx -s reload; then
  restore_rescue
  echo "ERROR: rollback reload failed; pre-rollback files restored" >&2
  exit 1
fi

echo "Rolled nginx routing back to backup stamp $STAMP"
echo "Pre-rollback rescue stamp: $RESCUE_STAMP"
