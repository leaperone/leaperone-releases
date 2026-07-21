# Public repository safety rules

This is a public release-automation repository. Treat every committed byte,
branch, pull request, workflow log, artifact, and Git object as public.

## Repository administration

- Do not change repository visibility, repository settings, branch protection,
  runner registration, or Git history unless the user explicitly requests that
  exact administrative operation.
- Do not make this repository private as an implementation detail.
- Production jobs must use GitHub-hosted runners. Do not add `self-hosted`
  labels or route jobs to private infrastructure runners.

## Information handling

- Never commit real server hostnames, IP addresses, SSH usernames, ports,
  filesystem layouts, inventories, network topology, credentials, tokens,
  database locations, backup locations, or operational evidence.
- Documentation and examples must use obvious placeholders such as
  `<DEPLOY_HOST>`, `<PORT>`, and `<REMOTE_PATH>`.
- Runtime infrastructure values must come from GitHub Secrets. Do not print
  their resolved values in workflow logs.
- Do not add an `ops/` directory, infrastructure runbooks, migration journals,
  cutover records, or server-specific README content.
- Before committing, scan all changed files and generated output for
  infrastructure identifiers and redact them.

## Product boundary

- Private products and their deployment/runtime details belong only in their
  private repositories. Do not add their workflows, compose manifests,
  documentation, secrets, artifacts, or source references here.
- Keep changes limited to public release automation. If a task needs private
  infrastructure context, stop and move that work to the appropriate private
  repository.
