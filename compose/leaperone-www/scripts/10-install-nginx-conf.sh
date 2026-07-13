#!/usr/bin/env bash
set -euo pipefail

# Component releases are routing-free. The paired deploy workflow performs the
# only Nginx cutover after both component RepoDigests and health gates pass.
echo "WWW deployment complete; final routing is owned by the paired cutover workflow"
