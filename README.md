# Release automation

This public repository contains non-sensitive release workflows and deployment
templates for public projects.

Infrastructure values are supplied at runtime through GitHub Secrets. Server
inventories, migration runbooks, credentials, private product configuration,
and operational records do not belong in this repository.

See `AGENTS.md` before making changes.

Exact-build frontend source maps are fetched from the spool runner and uploaded to Sentry only (`.github/workflows/upload-telemetry-sourcemaps.yml`); PostHog exception/sourcemap upload is not part of this automation.

Overseas LEAPERone and MultiPost releases publish to a configurable registry;
see `docs/overseas-registry.md`.
