# Release automation

This public repository contains non-sensitive release workflows and deployment
templates for public projects.

Infrastructure values are supplied at runtime through GitHub Secrets. Server
inventories, migration runbooks, credentials, private product configuration,
and operational records do not belong in this repository.

See `AGENTS.md` before making changes.

UnderSky frontend and backend checks and deployment are defined in
`.github/workflows/ci-undersky.yml` and `deploy-undersky-core.yml`. The private
application repository calls a pinned commit of these reusable workflows.
Execution, credentials, logs, and artifacts belong to the private caller.
CLI automation remains in the application repository.
