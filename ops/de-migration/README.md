# DokiLove / MultiPost Germany Migration

Runbook for moving DokiLove and MultiPost from PVE LXC 200 to the Germany host.

## Prepared State

- Germany host: `de.leaper.one`
- App layout: `/opt/apps/<project>/production`, matching PVE LXC 200.
- Docker network: `leaperone-prod`
- PostgreSQL: Docker Compose at `/opt/apps/postgres/production`, image `registry.cn-hongkong.aliyuncs.com/leaperone/postgres:16.14-bookworm`
- Registry: `registry.cn-hongkong.aliyuncs.com`; Germany production images, including mirrored official/third-party images, are pulled from this registry.
- Maintenance Worker: `leaperone-maintenance`

## Cutover Order

1. Enable maintenance routes:
   ```bash
   ops/de-migration/enable-maintenance.sh
   ```
2. Stop PVE write-side containers:
   ```bash
   ops/de-migration/stop-pve-services.sh
   ```
3. Dump compressed PostgreSQL archives on PVE and SCP them directly to DE:
   ```bash
   ops/de-migration/dump-and-copy-db.sh
   ```
4. Restore dumps into the DE Postgres container:
   ```bash
   ops/de-migration/restore-db-on-de.sh
   ```
5. Start DE services and verify origin with `curl --resolve`.
6. Switch Cloudflare DNS to `159.195.43.38`:
   ```bash
   ops/de-migration/cutover-dns-to-de.sh
   ```
7. Disable maintenance:
   ```bash
   ops/de-migration/disable-maintenance.sh
   ```

After DE receives real writes, do not switch DNS back to PVE without a reverse data migration.
