# Vibeface app deployment

`deploy-vibeface-app` receives an exact stable app tag and source commit from the Vibeface release workflow.
The receiver requires the source to be on `main`, verifies the public release manifest and component hashes, and installs the archive's `web` directory as an immutable release named by its source SHA.
It does not rebuild the app.

The existing Nginx configuration must serve only the app hostname, contain one versioned `root`, and have one `Content-Security-Policy` and one `X-Vibeface-Source` header.
Activation replaces only those three directive values. The CSP comes from the verified app build receipt.
It preserves the other Nginx settings and previous releases, checks Nginx configuration, reloads the service, verifies the index through loopback HTTPS, and then updates the existing sibling `current` symlink.
A configuration, reload, or loopback failure restores the previous configuration and reloads it.

The workflow uses these existing credentials:

- `ACCESS_TOKEN` reads the source repository and its release assets.
- `DE_APP_HOST`, `DE_APP_USERNAME`, and `DE_APP_SSH_KEY` connect to the deployment host.
- `DE_APP_SSH_HOST_KEY` must contain a matching OpenSSH `known_hosts` entry. A bare fingerprint is insufficient.
- `DE_APP_PORT` is an optional repository variable. It defaults to the standard SSH port.

The deployment also requires these repository Secrets:

- `VIBEFACE_APP_RELEASES_DIR` is the existing absolute releases directory, such as `<RELEASES_PATH>`. Its sibling `current` symlink must point to the current Nginx root.
- `VIBEFACE_APP_NGINX_CONFIG` is the existing app-only Nginx configuration file, such as `<CONFIG_PATH>`.
- `VIBEFACE_APP_URL` is the public HTTPS origin, such as `<HTTPS_ORIGIN>`.

The SSH account must be root or have non-interactive sudo permission for activation. The host needs Python 3, Nginx, systemd, and curl. Activation must be able to write the release directory, configuration file, and current symlink, and reload Nginx.

After activation, HTTP smoke requires `/`, `/connect`, `/join`, and startup assets referenced by the index to return 200 with the published bytes. It also checks the source header, CSP, and uncached HTML. Redirect loops, cross-origin redirects, missing resources, and stale content fail the job.
The hosted smoke failure does not automatically roll back an already activated release.

Prereleases cannot enter this workflow. Successful dispatch is only a request; check the receiving workflow result before reporting deployment success.
