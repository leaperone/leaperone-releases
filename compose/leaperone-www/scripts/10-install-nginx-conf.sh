#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

NGINX_ROUTING_MODE="${NGINX_ROUTING_MODE:-off}"
case "$NGINX_ROUTING_MODE" in
  off)
    echo "NGINX_ROUTING_MODE=off; keeping the current nginx routing"
    exit 0
    ;;
  candidate)
    SOURCE_CONFIG="nginx/leaperone-candidate-local.conf"
    ;;
  cutover)
    SOURCE_CONFIG="nginx/leaperone-cutover-local.conf"
    ;;
  *)
    echo "ERROR: NGINX_ROUTING_MODE must be off, candidate, or cutover" >&2
    exit 1
    ;;
esac

for command in curl flock install mktemp nginx openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $command" >&2
    exit 1
  }
done

CERT_DIR="${LEAPERONE_TLS_CERT_DIR:-/etc/nginx/ssl/leaper.one}"
CERT_FILE="${CERT_DIR}/fullchain.cer"
KEY_FILE="${CERT_DIR}/leaper.one.key"
SOURCE_HEADERS="nginx/leaperone-proxy-headers.conf"
TARGET_CONFIG="/etc/nginx/sites-enabled/leaperone-local.conf"
TARGET_HEADERS="/etc/nginx/snippets/leaperone-proxy-headers.conf"
BACKUP_DIR="/etc/nginx/backups/leaperone"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[ -f "$CERT_FILE" ] || { echo "ERROR: missing TLS certificate: $CERT_FILE" >&2; exit 1; }
[ -f "$KEY_FILE" ] || { echo "ERROR: missing TLS key: $KEY_FILE" >&2; exit 1; }
[ -f "$SOURCE_CONFIG" ] || { echo "ERROR: missing nginx config for mode $NGINX_ROUTING_MODE" >&2; exit 1; }
[ -f "$SOURCE_HEADERS" ] || { echo "ERROR: missing candidate proxy header snippet" >&2; exit 1; }

for hostname in leaper.one www.leaper.one api.leaper.one dashboard.leaper.one next.leaper.one; do
  openssl x509 -in "$CERT_FILE" -noout -checkhost "$hostname" >/dev/null 2>&1 || {
    echo "ERROR: TLS certificate does not cover $hostname" >&2
    exit 1
  }
done

# Candidate services must already be healthy before any live nginx file changes.
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9820/api/health >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9821/api/ready >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9801/health >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9800/api/health >/dev/null

exec 9>/run/lock/leaperone-nginx-install.lock
flock -x 9

install -d -m 0755 "$BACKUP_DIR" /etc/nginx/snippets
CONFIG_CANDIDATE="$(mktemp /etc/nginx/.leaperone-local.conf.candidate.XXXXXX)"
HEADERS_CANDIDATE="$(mktemp /etc/nginx/.leaperone-proxy-headers.conf.candidate.XXXXXX)"
trap 'rm -f "$CONFIG_CANDIDATE" "$HEADERS_CANDIDATE"' EXIT
install -m 0644 "$SOURCE_CONFIG" "$CONFIG_CANDIDATE"
install -m 0644 "$SOURCE_HEADERS" "$HEADERS_CANDIDATE"

HAD_CONFIG=false
HAD_HEADERS=false
CONFIG_BACKUP="${BACKUP_DIR}/leaperone-local.conf.${STAMP}"
HEADERS_BACKUP="${BACKUP_DIR}/leaperone-proxy-headers.conf.${STAMP}"
if [ -f "$TARGET_CONFIG" ]; then
  install -m 0644 "$TARGET_CONFIG" "$CONFIG_BACKUP"
  HAD_CONFIG=true
else
  : > "${CONFIG_BACKUP}.absent"
fi
if [ -f "$TARGET_HEADERS" ]; then
  install -m 0644 "$TARGET_HEADERS" "$HEADERS_BACKUP"
  HAD_HEADERS=true
else
  : > "${HEADERS_BACKUP}.absent"
fi

restore_previous() {
  echo "Restoring previous nginx configuration..." >&2
  if [ "$HAD_CONFIG" = true ]; then
    install -m 0644 "$CONFIG_BACKUP" "$TARGET_CONFIG"
  else
    rm -f "$TARGET_CONFIG"
  fi
  if [ "$HAD_HEADERS" = true ]; then
    install -m 0644 "$HEADERS_BACKUP" "$TARGET_HEADERS"
  else
    rm -f "$TARGET_HEADERS"
  fi
  nginx -t
  nginx -s reload
}

# Both moves are same-filesystem replacements. Nginx is reloaded only after
# the complete candidate pair passes nginx -t.
mv -f "$HEADERS_CANDIDATE" "$TARGET_HEADERS"
mv -f "$CONFIG_CANDIDATE" "$TARGET_CONFIG"

if ! nginx -t; then
  restore_previous
  echo "ERROR: candidate nginx configuration failed validation" >&2
  exit 1
fi

if ! nginx -s reload; then
  restore_previous
  echo "ERROR: nginx reload failed; previous configuration restored" >&2
  exit 1
fi

echo "Installed LEAPERone nginx routing mode '$NGINX_ROUTING_MODE' atomically"
echo "Rollback stamp: $STAMP"
