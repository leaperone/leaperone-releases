# LEAPERone API production compose

This directory is synchronized to `/opt/apps/leaperone/production`. It owns
only `leaperone-api-production`; WWW and Dashboard have separate projects and
the retired legacy Web must never be started by an API release.

Server-only files:

- `.env` is Docker Compose interpolation data. Keep `DEPLOY_ENV`,
  `REGISTRY_HOST`, `API_PORT`, and API worker flags here.
- `.env.api` contains API runtime variables and secrets.
- `alipay-cert/` contains the certificates mounted read-only for callback
  verification.

Both env files must remain `root:root`, mode `0600`, and must not be committed.
The workflow supplies an immutable `API_IMAGE_TAG=api-<source-sha>`;
production never deploys `api-latest`.

The existing API workflow remains the owner of its reviewed database migration
step before the API container is replaced. This API-only retirement does not
change that migration contract. The separate WWW/Dashboard workflows and
one-shot frontend cutover continue to record `"migration":"none"` and never
open a database tunnel or run `db:migrate`.

## Legacy Web retirement

The first API-only `docker compose up --remove-orphans` removes any stopped
`leaperone-web-production` orphan. Before that first release, retain its
immutable image metadata and `.env.web` as root-only cold rollback evidence.
Because overwrite-only SCP leaves deleted repository files on the server, the
DE deploy entrypoint first copies any stale legacy Nginx installer/config to
`/var/lib/leaperone/retired-release-payloads`, records its SHA256 and releases
SHA, and removes it from the active app directory. The generic deployer also
disables all post-deploy scripts for this API-only project.
After the rollback window, archive or remove `.env.web` and delete stale
`WEB_IMAGE_TAG`, `WEB_PORT`, and `INSTALL_NGINX_CONF` entries from `.env`.

There is no Nginx payload in this project. Final routing is owned only by the
reviewed frontend cutover configuration under `ops/leaperone-frontend/`.
