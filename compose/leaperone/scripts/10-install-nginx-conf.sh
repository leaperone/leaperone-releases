#!/usr/bin/env bash
set -euo pipefail

# The legacy Web/API compose must never overwrite split frontend routing after
# cutover. The active LEAPERone nginx file is now exclusively managed by
# compose/leaperone-www/scripts/10-install-nginx-conf.sh, which has candidate
# health checks, backups, validation, failure restoration, and rollback data.
echo "Legacy LEAPERone nginx installer retired; leaving active routing unchanged"
