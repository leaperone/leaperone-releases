# Public release automation

Treat committed files, branches, pull requests, workflows, logs and artifacts as public.

- Keep existing public release automation functional. New private product automation belongs in the owning private repository.
- Production jobs use GitHub-hosted runners. Existing telemetry upload jobs may use the approved PVE runner.
- Read repository and runtime state before making changes. Preserve unrelated work.
- Infrastructure values and credentials come from GitHub Secrets. Never commit server identifiers, paths, inventories, network topology or operational evidence.
- Documentation uses placeholders such as <DEPLOY_HOST>, <PORT> and <REMOTE_PATH>.
- Do not add ops directories, cutover records, private source or deployment logs.
- Do not change visibility, ownership, branch protection or history without explicit user authorization.
- After an authorized history rewrite, refresh the checkout before new work so old Git objects are not reintroduced.
