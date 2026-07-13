#!/usr/bin/env bash
set -euo pipefail

# Legacy Web/API releases must never overwrite the split frontend routing.
echo "Legacy Web/API deployment complete; Nginx routing is managed separately"
