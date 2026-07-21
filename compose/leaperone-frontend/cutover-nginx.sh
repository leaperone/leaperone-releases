#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SOURCE_SHA="${SOURCE_SHA:?SOURCE_SHA is required}"
WWW_IMAGE_REF="${WWW_IMAGE_REF:?WWW_IMAGE_REF is required}"
WWW_IMAGE_DIGEST="${WWW_IMAGE_DIGEST:?WWW_IMAGE_DIGEST is required}"
DASHBOARD_IMAGE_REF="${DASHBOARD_IMAGE_REF:?DASHBOARD_IMAGE_REF is required}"
DASHBOARD_IMAGE_DIGEST="${DASHBOARD_IMAGE_DIGEST:?DASHBOARD_IMAGE_DIGEST is required}"
RELEASES_SHA="${RELEASES_SHA:?RELEASES_SHA is required}"

[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid source SHA" >&2; exit 1; }
[[ "$RELEASES_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid releases SHA" >&2; exit 1; }
[[ "$WWW_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: invalid WWW digest" >&2; exit 1; }
[[ "$DASHBOARD_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: invalid Dashboard digest" >&2; exit 1; }

REGISTRY_IMAGE="registry.cn-hongkong.aliyuncs.com/leaperone/leaperone"
[ "$WWW_IMAGE_REF" = "${REGISTRY_IMAGE}:www-${SOURCE_SHA}" ] || {
  echo "ERROR: WWW image does not match the paired source SHA" >&2
  exit 1
}
[ "$DASHBOARD_IMAGE_REF" = "${REGISTRY_IMAGE}:dashboard-${SOURCE_SHA}" ] || {
  echo "ERROR: Dashboard image does not match the paired source SHA" >&2
  exit 1
}

for command in curl docker flock install mktemp nginx openssl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $command" >&2
    exit 1
  }
done

verify_repo_digest() {
  local container="$1"
  local image_ref="$2"
  local digest="$3"
  local repository="${image_ref%:*}"
  local expected="${repository}@${digest}"
  local image_id

  image_id="$(docker inspect --format '{{.Image}}' "$container")"
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" \
    | grep -Fxq "$expected" || {
      echo "ERROR: $container is not running expected RepoDigest $expected" >&2
      exit 1
    }
}

verify_repo_digest leaperone-www-production "$WWW_IMAGE_REF" "$WWW_IMAGE_DIGEST"
verify_repo_digest leaperone-dashboard-production "$DASHBOARD_IMAGE_REF" "$DASHBOARD_IMAGE_DIGEST"

curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9820/api/health >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9821/api/ready >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9801/health >/dev/null

CERT_DIR="${LEAPERONE_TLS_CERT_DIR:-/etc/nginx/ssl/leaper.one}"
CERT_FILE="${CERT_DIR}/fullchain.cer"
KEY_FILE="${CERT_DIR}/leaper.one.key"
SOURCE_CONFIG="leaperone-local.conf"
SOURCE_HEADERS="leaperone-proxy-headers.conf"
TARGET_CONFIG="/etc/nginx/sites-enabled/leaperone-local.conf"
TARGET_HEADERS="/etc/nginx/snippets/leaperone-proxy-headers.conf"
BACKUP_DIR="/etc/nginx/backups/leaperone"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

[ -f "$CERT_FILE" ] || { echo "ERROR: missing TLS certificate: $CERT_FILE" >&2; exit 1; }
[ -f "$KEY_FILE" ] || { echo "ERROR: missing TLS key: $KEY_FILE" >&2; exit 1; }
[ -f "$SOURCE_CONFIG" ] || { echo "ERROR: missing final nginx configuration" >&2; exit 1; }
[ -f "$SOURCE_HEADERS" ] || { echo "ERROR: missing proxy header snippet" >&2; exit 1; }

for hostname in leaper.one www.leaper.one api.leaper.one dashboard.leaper.one; do
  openssl x509 -in "$CERT_FILE" -noout -checkhost "$hostname" >/dev/null 2>&1 || {
    echo "ERROR: TLS certificate does not cover $hostname" >&2
    exit 1
  }
done

exec 9>/run/lock/leaperone-nginx-install.lock
flock -x 9

install -d -m 0755 "$BACKUP_DIR" /etc/nginx/snippets
CONFIG_CANDIDATE="$(mktemp /etc/nginx/.leaperone-local.conf.final.XXXXXX)"
HEADERS_CANDIDATE="$(mktemp /etc/nginx/.leaperone-proxy-headers.conf.final.XXXXXX)"
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

smoke_final_routes() {
  curl --noproxy '*' --fail --silent --show-error --max-time 10 \
    --resolve leaper.one:443:127.0.0.1 https://leaper.one/api/health >/dev/null
  curl --noproxy '*' --fail --silent --show-error --max-time 10 \
    --resolve dashboard.leaper.one:443:127.0.0.1 https://dashboard.leaper.one/api/ready >/dev/null
  curl --noproxy '*' --fail --silent --show-error --max-time 10 \
    --resolve api.leaper.one:443:127.0.0.1 https://api.leaper.one/health >/dev/null
}

mv -f "$HEADERS_CANDIDATE" "$TARGET_HEADERS"
mv -f "$CONFIG_CANDIDATE" "$TARGET_CONFIG"

if ! nginx -t; then
  restore_previous
  echo "ERROR: final nginx configuration failed validation" >&2
  exit 1
fi
if ! nginx -s reload; then
  restore_previous
  echo "ERROR: nginx reload failed; previous configuration restored" >&2
  exit 1
fi
if ! smoke_final_routes; then
  restore_previous
  echo "ERROR: final route smoke failed; previous configuration restored" >&2
  exit 1
fi

: "${DEPLOY_STATE_ROOT:?DEPLOY_STATE_ROOT must be supplied by the deployment environment}"
RECORD_DIR="${DEPLOY_STATE_ROOT}/deployments"
RECORD_FILE="${RECORD_DIR}/frontend-cutovers.jsonl"
install -d -m 0700 "$RECORD_DIR"
if [ ! -f "$RECORD_FILE" ]; then
  install -m 0600 /dev/null "$RECORD_FILE"
fi
chmod 0600 "$RECORD_FILE"
printf '{"source_sha":"%s","releases_sha":"%s","www_image_ref":"%s","www_image_digest":"%s","dashboard_image_ref":"%s","dashboard_image_digest":"%s","nginx_backup_stamp":"%s","cutover_at":"%s","migration":"none"}\n' \
  "$SOURCE_SHA" "$RELEASES_SHA" "$WWW_IMAGE_REF" "$WWW_IMAGE_DIGEST" \
  "$DASHBOARD_IMAGE_REF" "$DASHBOARD_IMAGE_DIGEST" "$STAMP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "$RECORD_FILE"

echo "Installed final LEAPERone routing atomically"
echo "Rollback stamp: $STAMP"
