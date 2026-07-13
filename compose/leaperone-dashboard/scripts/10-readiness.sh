#!/usr/bin/env bash
set -euo pipefail

# The image HEALTHCHECK proves the Next.js process is alive. This external gate
# additionally proves Dashboard can reach its database without exposing error
# details. It runs after docker compose up --wait and before workflow success.
for attempt in $(seq 1 12); do
  if curl --fail --silent --show-error --max-time 5 \
    http://127.0.0.1:9821/api/ready >/dev/null; then
    echo "Dashboard readiness passed on attempt $attempt"
    exit 0
  fi
  if [ "$attempt" -lt 12 ]; then
    sleep 5
  fi
done

echo "ERROR: Dashboard readiness failed at 127.0.0.1:9821/api/ready" >&2
exit 1
