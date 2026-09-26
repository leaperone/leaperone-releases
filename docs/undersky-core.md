# UnderSky core deployment

`deploy-undersky-core.yml` is a manual, digest-pinned deployment for the three
core containers on the Germany application host:

- `www` serves `undersky.ai`.
- `dashboard` serves `dashboard.undersky.ai`.
- `api` serves `api.undersky.ai`.

The workflow requires an exact UnderSky source SHA. It builds each image on an
independent GitHub-hosted runner, publishes
`registry.cn-hongkong.aliyuncs.com/leaperone/undersky:{www|dashboard|api}-SHA`,
and deploys the resulting manifest digests only when the `deploy` input is
explicitly enabled. It never changes Nginx or DNS.

Before the first deployment, the host administrator must create
`<APP_DEPLOY_ROOT>/undersky-core/production/.env`, `.env.www`,
`.env.dashboard`, and `.env.api`, all mode `0600`. The root file supplies
`WWW_PORT`, `DASHBOARD_PORT`, and `API_PORT`; the service files supply runtime
settings and secrets. `.env.api` and `.env.dashboard` must use the existing
`leaperone_db` database. The preflight rejects a different database name,
enabled media workers, or enabled migrations. Dashboard `API_URL` remains
`https://api.leaper.one` during this phase so legacy control-plane routes stay
available while the UnderSky Rust API handles model traffic.

The host must provide Docker Compose, `curl`, and the existing registry access.
The ports are loopback-only and intentionally come from the host environment;
the existing external Docker network `leaperone-prod` must also be present so
the Dashboard and Rust API can reach the host PostgreSQL service. The Nginx
owner can add routing after the containers pass database readiness checks.

`deploy-core.sh` saves the fully resolved previous Compose model before pulling
the new images. `rollback.sh` restores that model and waits for all three
health checks. Both scripts leave Nginx untouched and perform no database
migrations.

After a successful deployment, inspect the containers with both environment files:

```bash
docker compose --env-file .env --env-file .images.env ps
```

Render the candidate Nginx files using the allocated host ports:

```bash
python3 render-nginx.py --www-port 9860 --dashboard-port 9861 --api-port 9862 --output-dir /root/undersky-nginx-candidate
```

Install the site file only after verifying container readiness and the TLS
certificate for `undersky.ai` and `*.undersky.ai`. The model-route snippet moves
only Chat, Responses, Messages, and Embeddings. The remaining API routes use
the existing Leaper One API on loopback port 9801. Back up the active Nginx
configuration before installing the files, then run `nginx -t` before reload.

The same model-route snippet can later be included in the existing
`api.leaper.one` server block after UnderSky accepts real requests. Removing
that include and reloading Nginx restores the old model routes without
replaying requests or changing the database.

Core acceptance requires an OAuth login on `dashboard.undersky.ai`, an API key
created in that Dashboard, and a successful model request with that key.
Configure new OAuth callbacks for the Dashboard origin. The old Hong Kong
UnderSky credentials are outside this deployment.
