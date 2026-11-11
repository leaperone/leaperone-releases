# Configure SaraClick production releases

The `deploy-saraclick` repository dispatch builds the web and backend together.
It publishes images to the production registry, runs Prisma migrations through
an SSH tunnel, and deploys both images by digest. The workflow uses the existing
`main` or release-tag source contract. An optional `source_sha` must match the
checked-out source.

## Set the release secrets

Configure these secrets in this repository or grant this repository access to
the corresponding organization secrets:

- `ACCESS_TOKEN` grants read access to `leaperone/SaraClick`.
- `DE_REGISTRY_HOST`, `DE_REGISTRY_USERNAME`, and `DE_REGISTRY_PASSWORD` grant
  image push access to the production registry.
- `DE_APP_HOST`, `DE_APP_USERNAME`, and `DE_APP_SSH_KEY` grant SSH access to the
  production deployment host.
- `DE_APP_SSH_HOST_KEY` contains a matching OpenSSH `known_hosts` entry. A bare
  fingerprint is insufficient.
- `SARACLICK_DEPLOY_ROOT` contains the absolute production application directory.
- `SARACLICK_DATABASE_URL` uses the `saraclick_app` role and `saraclick_db`
  database through `127.0.0.1:15432`, with `sslmode=disable`. Preserve required
  Prisma query parameters. The workflow forwards this local port to PostgreSQL
  on the deployment host. This URL is specific to the migration runner.

Set the optional repository variable `DE_APP_PORT` if SSH uses a different port.
The workflow no longer reads the legacy application host, deployment script,
or registry credentials.

## Prepare the application directory

Complete the first application and database cutover before enabling routine
releases. Keep the old backend stopped before starting the new backend. The
backend schedules publish jobs at startup and recovers interrupted tasks.

1. Create `<REMOTE_PATH>/web.env` and `<REMOTE_PATH>/backend.env` with the existing
   production settings. Set both database URLs to the production database with
   the `saraclick_app` role. Preserve the public domain, OAuth redirect URLs,
   payment webhook settings, and application secrets.
2. Create `<REMOTE_PATH>/deployment.env` with the following literal, unquoted
   values. Use the actual production settings in place of the placeholders.

   ```dotenv
	SARACLICK_WEB_BIND=<LOOPBACK_ADDRESS>:<WEB_PORT>
	SARACLICK_NETWORK=<EXTERNAL_DOCKER_NETWORK>
	SARACLICK_DATABASE_HOST=<DATABASE_DOCKER_HOST>
	SARACLICK_DATABASE_PORT=<DATABASE_PORT>
   ```

3. Set mode `600` on all three environment files. Keep registry pull credentials
   available to the SSH deployment user on the host.
4. Record the accepted image pair in `<REMOTE_PATH>/release.env` as
   `SARACLICK_WEB_IMAGE=<REGISTRY>/leaperone/saraclick@sha256:<DIGEST>` and
   `SARACLICK_BACKEND_IMAGE=<REGISTRY>/leaperone/saraclick@sha256:<DIGEST>`.
   For the initial imported images, an immutable local Docker image ID is also
   valid. Keep those images on the host until a registry-backed release succeeds.
5. After verifying the first cutover, create the empty file
   `<REMOTE_PATH>/.cutover-complete`. The workflow refuses migrations and
   routine deployment without this file.

The host requires Docker Compose v2.30.0 or newer for raw env files, `--wait`, and multiple `--env-file`
support, Python 3, and `flock`. The compose manifest uses the existing
`saraclick` and `saraclick-backend` service aliases. The backend port stays
internal to the external Docker network. This automation does not configure
DNS, public certificates, or Nginx.

## Check a release

Review the migration result and deployment result separately. The deployment
checks both HTTP health endpoints and runs `SELECT 1` through the backend's
actual Prisma client. If deployment fails, inspect the private
`<REMOTE_PATH>/.deploy-diagnostic` file.

A failed application health check attempts to restore the previous image pair
from `release.env`. Database migrations are not rolled back. Select an older
application version only after checking its compatibility with the current
schema. Environment files remain the current production files during image
rollback, and the runtime database guard rejects a different database target.
