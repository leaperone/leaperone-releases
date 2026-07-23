#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "Usage: $0 <relative-bundle-key>" >&2
  exit 2
}

bundle_key="$1"

: "${SOURCEMAP_SPOOL_HOST:?missing SOURCEMAP_SPOOL_HOST}"
: "${SOURCEMAP_SPOOL_USERNAME:?missing SOURCEMAP_SPOOL_USERNAME}"
: "${SOURCEMAP_SPOOL_SSH_KEY:?missing SOURCEMAP_SPOOL_SSH_KEY}"
: "${SOURCEMAP_SPOOL_ROOT:?missing SOURCEMAP_SPOOL_ROOT}"

spool_port="${SOURCEMAP_SPOOL_PORT:-22}"

case "$bundle_key" in
  ""|/*|*".."*|*[!A-Za-z0-9._/-]*)
    echo "ERROR: invalid relative source map bundle key" >&2
    exit 1
    ;;
esac
case "$SOURCEMAP_SPOOL_ROOT" in
  /*) ;;
  *)
    echo "ERROR: SOURCEMAP_SPOOL_ROOT must be an absolute path" >&2
    exit 1
    ;;
esac
case "$SOURCEMAP_SPOOL_ROOT" in
  *".."*|*[!A-Za-z0-9._/-]*)
    echo "ERROR: SOURCEMAP_SPOOL_ROOT contains unsupported characters" >&2
    exit 1
    ;;
esac

key_file="$(mktemp)"
known_hosts_file="$(mktemp)"
cleanup() {
  rm -f "$key_file" "$known_hosts_file"
}
trap cleanup EXIT

umask 077
printf '%s\n' "$SOURCEMAP_SPOOL_SSH_KEY" > "$key_file"
ssh-keyscan -H -p "$spool_port" "$SOURCEMAP_SPOOL_HOST" > "$known_hosts_file" 2>/dev/null

remote_bundle="${SOURCEMAP_SPOOL_ROOT%/}/$bundle_key"
ssh \
  -i "$key_file" \
  -p "$spool_port" \
  -o "UserKnownHostsFile=$known_hosts_file" \
  -o StrictHostKeyChecking=yes \
  -o BatchMode=yes \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST" \
  "rm -f -- \"$remote_bundle\" \"$remote_bundle.sha256\""

echo "Source map spool files removed."
