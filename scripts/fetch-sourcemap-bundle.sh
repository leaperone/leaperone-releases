#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <relative-bundle-key> <local-bundle.tar>" >&2
}

[ "$#" -eq 2 ] || {
  usage
  exit 2
}

bundle_key="$1"
bundle_path="$2"

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
case "$spool_port" in
  ""|*[!0-9]*)
    echo "ERROR: SOURCEMAP_SPOOL_PORT must be numeric" >&2
    exit 1
    ;;
esac

key_file="$(mktemp)"
known_hosts_file="$(mktemp)"
checksum_path="${bundle_path}.sha256"
cleanup() {
  rm -f "$key_file" "$known_hosts_file" "$checksum_path"
}
trap cleanup EXIT

umask 077
install -d -m 700 "$(dirname "$bundle_path")"
printf '%s\n' "$SOURCEMAP_SPOOL_SSH_KEY" > "$key_file"
ssh-keyscan -H -p "$spool_port" "$SOURCEMAP_SPOOL_HOST" > "$known_hosts_file" 2>/dev/null

remote_bundle="${SOURCEMAP_SPOOL_ROOT%/}/$bundle_key"
rsync_command="ssh -i \"$key_file\" -p \"$spool_port\" -o UserKnownHostsFile=\"$known_hosts_file\" -o StrictHostKeyChecking=yes -o BatchMode=yes"

rsync -a \
  --partial \
  --append-verify \
  -e "$rsync_command" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST:$remote_bundle" \
  "$bundle_path"

rsync -a \
  -e "$rsync_command" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST:$remote_bundle.sha256" \
  "$checksum_path"

expected_checksum="$(tr -d '[:space:]' < "$checksum_path")"
actual_checksum="$(sha256sum "$bundle_path" | awk '{print $1}')"
if ! [[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: invalid source map checksum" >&2
  exit 1
fi
if [ "$expected_checksum" != "$actual_checksum" ]; then
  echo "ERROR: source map bundle checksum mismatch" >&2
  exit 1
fi

echo "Source map bundle fetched and verified."
