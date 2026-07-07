#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ "${INSTALL_NGINX_CONF:-false}" != "true" ]; then
  echo "INSTALL_NGINX_CONF is not true; skipping nginx config install"
  exit 0
fi

CERT_DIR="${LEAPERONE_TLS_CERT_DIR:-/etc/nginx/ssl/leaper.one}"
if [ ! -f "${CERT_DIR}/fullchain.cer" ] || [ ! -f "${CERT_DIR}/leaper.one.key" ]; then
  echo "Missing TLS files under ${CERT_DIR}; refusing to install nginx config" >&2
  exit 1
fi

install -m 0644 nginx/leaperone-local.conf /etc/nginx/sites-enabled/leaperone-local.conf
nginx -t
nginx -s reload
echo "installed /etc/nginx/sites-enabled/leaperone-local.conf"
