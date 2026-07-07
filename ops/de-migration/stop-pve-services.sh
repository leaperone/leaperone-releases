#!/usr/bin/env bash
set -euo pipefail

ssh root@pve.leaper.one "pct exec 200 -- bash -lc '
set -euo pipefail
docker stop \
  dokilove-web-production \
  dokilove-worker-production \
  dokilove-tg-bot-production \
  dokilove-flaresolverr-production \
  multipost-backend-production \
  multipost-web-blue-web-1 \
  multipost-web-green-web-1 \
  multipost-video-stt-worker-production \
  2>/dev/null || true
docker ps --format \"table {{.Names}}\t{{.Status}}\" | grep -Ei \"doki|multipost\" || true
'"
