# LEAPERone production compose

The files in this directory are synchronized to
`/opt/apps/leaperone/production` by the deployment workflow.

The server-side environment is intentionally split:

- `.env` is read by Docker Compose for interpolation only. Keep deployment
  settings such as `DEPLOY_ENV`, `REGISTRY_HOST`, ports, runtime-role flags,
  and other compose substitutions here.
- `.env.web` contains the web application's runtime variables and secrets.
- `.env.api` contains the API application's runtime variables and secrets.

All three files are production-only, mode `0600`, and must not be committed.
The workflow supplies `WEB_IMAGE_TAG=web-<source-sha>` and
`API_IMAGE_TAG=api-<source-sha>` to Docker Compose for each deployment, so the
running containers never depend on a mutable `latest` tag.

Alipay certificate mode also requires the server-only `alipay-cert/` directory
next to the Compose file. It is mounted read-only into both services at
`/app/alipay-cert`; Web uses all three certificates to create payment requests,
while API uses the Alipay public certificate to verify callbacks. The directory
must contain:

- `appCertPublicKey_<app-id>.crt`
- `alipayCertPublicKey_RSA2.crt`
- `alipayRootCert.crt`

## One-time migration from the legacy shared `.env`

This compose change deliberately fails closed until `.env.web` and `.env.api`
exist. Before the first deployment, back up the legacy file and create both
service files. A conservative transition is to copy the existing shared file
to both service files first (this preserves the old runtime behavior), then
reduce each file to the variables its service actually needs. Finally replace
root `.env` with compose-only settings.

Do this as a separately reviewed production configuration change. Do not let
the deployment workflow guess how secrets should be assigned to services.
