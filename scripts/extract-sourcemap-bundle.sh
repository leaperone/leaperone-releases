#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "Usage: $0 <bundle.tar> <destination-directory>" >&2
  exit 2
}

bundle_path="$1"
destination="$2"

[ -s "$bundle_path" ] || {
  echo "ERROR: source map bundle is missing or empty" >&2
  exit 1
}

while IFS= read -r entry; do
  case "$entry" in
    ""|/*|../*|*/../*|*/..)
      echo "ERROR: unsafe path in source map bundle" >&2
      exit 1
      ;;
  esac
done < <(tar -tf "$bundle_path")

if tar -tvf "$bundle_path" | awk '$1 !~ /^[-d]/ { unsafe = 1 } END { exit !unsafe }'; then
  echo "ERROR: source map bundle contains links or special files" >&2
  exit 1
fi

rm -rf "$destination"
install -d -m 700 "$destination"
tar --no-same-owner --no-same-permissions -xf "$bundle_path" -C "$destination"

if ! find "$destination" -type f -name '*.map' -print -quit | grep -q .; then
  echo "ERROR: source map bundle contains no .map files" >&2
  exit 1
fi

echo "Source map bundle extracted successfully."
