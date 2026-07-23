#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <local-bundle.tar> <relative-bundle-key>" >&2
}

[ "$#" -eq 2 ] || {
  usage
  exit 2
}

bundle_path="$1"
bundle_key="$2"

: "${SOURCEMAP_SPOOL_HOST:?missing SOURCEMAP_SPOOL_HOST}"
: "${SOURCEMAP_SPOOL_USERNAME:?missing SOURCEMAP_SPOOL_USERNAME}"
: "${SOURCEMAP_SPOOL_SSH_KEY:?missing SOURCEMAP_SPOOL_SSH_KEY}"
: "${SOURCEMAP_SPOOL_ROOT:?missing SOURCEMAP_SPOOL_ROOT}"

spool_port="${SOURCEMAP_SPOOL_PORT:-22}"

[ -s "$bundle_path" ] || {
  echo "ERROR: source map bundle is missing or empty" >&2
  exit 1
}

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
checksum_file="$(mktemp)"
cleanup() {
  rm -f "$key_file" "$known_hosts_file" "$checksum_file"
}
trap cleanup EXIT

umask 077
printf '%s\n' "$SOURCEMAP_SPOOL_SSH_KEY" > "$key_file"
ssh-keyscan -H -p "$spool_port" "$SOURCEMAP_SPOOL_HOST" > "$known_hosts_file" 2>/dev/null

checksum="$(sha256sum "$bundle_path" | awk '{print $1}')"
printf '%s\n' "$checksum" > "$checksum_file"

remote_bundle="${SOURCEMAP_SPOOL_ROOT%/}/$bundle_key"
remote_dir="${remote_bundle%/*}"
ssh_options=(
  -i "$key_file"
  -p "$spool_port"
  -o "UserKnownHostsFile=$known_hosts_file"
  -o StrictHostKeyChecking=yes
  -o BatchMode=yes
)

# The sanitized remote path is intentionally expanded locally.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST" \
  "umask 077; mkdir -p -- \"$remote_dir\""

rsync -a \
  --partial \
  --append-verify \
  --chmod=F600 \
  -e "ssh -i \"$key_file\" -p \"$spool_port\" -o UserKnownHostsFile=\"$known_hosts_file\" -o StrictHostKeyChecking=yes -o BatchMode=yes" \
  "$bundle_path" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST:$remote_bundle.partial"

rsync -a \
  --chmod=F600 \
  -e "ssh -i \"$key_file\" -p \"$spool_port\" -o UserKnownHostsFile=\"$known_hosts_file\" -o StrictHostKeyChecking=yes -o BatchMode=yes" \
  "$checksum_file" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST:$remote_bundle.sha256.partial"

# The sanitized remote path is intentionally expanded locally.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" \
  "$SOURCEMAP_SPOOL_USERNAME@$SOURCEMAP_SPOOL_HOST" \
  "set -e; chmod 600 -- \"$remote_bundle.partial\" \"$remote_bundle.sha256.partial\"; mv -f -- \"$remote_bundle.partial\" \"$remote_bundle\"; mv -f -- \"$remote_bundle.sha256.partial\" \"$remote_bundle.sha256\""

echo "Source map bundle staged successfully."
