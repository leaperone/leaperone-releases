# leaperone-release

## DokiLove / NIMEI production release

`deploy-dokilove` accepts `web`, `nimei`, `worker`, `tg-bot`, or `all` in the
repository-dispatch `components` payload. NIMEI runs on the same Germany host
and PostgreSQL database as DokiLove, under `/opt/apps/nimei/production`, with
blue/green ports 9811/9812.

The first rollout is deliberately special. While migration 0027 is absent,
the workflow rejects the historical default `components=web`; the dispatch
must explicitly select `nimei` or `all`. It then performs this order without an
automatic legacy rollback:

1. Resolve the requested ref once to a full Git SHA, verify optional
   `client_payload.source_sha`, and pin every checkout/build/migration to it.
2. Build DokiLove and NIMEI `web-<full-sha>` images, capture the registry
   manifest digests, and deploy by `repository@sha256` rather than by tag.
3. Validate NIMEI origin prerequisites before any database or DokiLove change:
   protected `.env`, independent auth secret, shared DB/encryption/OSS/Sentry,
   Resend, certificate, canonical Nginx, Docker network, and Compose config.
4. Switch DokiLove to the consumer-write-disabled image and verify the Germany
   origin returns HTTP 403 for registration, password changes, and passkey
   registration while session lookup/passkey authentication remain available.
5. Create and validate a remote custom-format `pg_dump` under
   `/opt/backups/dokilove-nimei-cutover/`.
6. Write a pending cutover journal, run migrations from `@dokilove/db`, and
   verify the identity snapshot.
7. Seal `/var/lib/dokilove/nimei-cutover-complete.json`; future DokiLove
   releases reject `latest` and unattested SHAs.
8. Deploy NIMEI and switch traffic only after its database-backed `/api/ready`
   succeeds through Germany Nginx.

The cutover state machine is retry-safe:

- `pending`: 0027 is absent. A `nimei`/`all` retry may replace the safe Doki
  image and backup/journal before retrying the migration.
- `migrated-unsealed`: 0027 is complete but the final marker is absent. The
  workflow requires a running digest-pinned, attested Doki image; rechecks all
  data and auth-freeze invariants; validates the matching backup; repairs the
  marker; then continues NIMEI. It never starts a legacy image.
- `sealed`: normal migration/deployment behavior resumes.

Legacy DokiLove passkeys are intentionally not copied because WebAuthn
credentials are bound to the `doki.love` RP ID. The workflow records their
count for audit, keeps the old table intact, and requires `nimei_passkey` to be
empty at first cutover; users sign in with migrated passwords and register a
new NIMEI passkey.

The NIMEI server `.env` uses a separate auth secret but must reuse DokiLove's
existing `ENCRYPTION_KEY` (for migrated BYOK ciphertext) and hot-OSS credentials
(for private-card media). It also points at the same `dokilove_db` over the
`leaperone-prod` Docker network. The preflight additionally requires mode
`400/600`, matching Sentry configuration, `TRUSTED_PROXY=1`, production URLs,
Resend, and a valid certificate/key pair.

PostHog and Sentry are shared with DokiLove: PostHog project 419311 uses the
`DOKILOVE_POSTHOG_PROJECT_KEY` repository secret and `https://t.doki.love`;
Sentry uses project `dokilove-web` and the existing DSN, with releases named
`dokilove-web@<sha>` and `nimei-web@<sha>`. Both telemetry streams retain an
`app` property/tag (`dokilove-web` or `nimei-web`) for filtering inside the
shared projects.

Bootstrap and rollback details are in `compose/nimei/BLUEGREEN.md`.
