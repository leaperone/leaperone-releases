# Overseas image registry

Overseas releases publish to one registry host selected per run:

| Release | Workflow |
| --- | --- |
| LEAPERone API | `deploy-leaperone.yml` |
| LEAPERone WWW and Dashboard (global) | `deploy-leaperone-frontend.yml` via `deploy-leaperone-www.yml`, `deploy-leaperone-dashboard.yml`, `deploy-leaperone-frontends.yml` |
| LEAPERone Email Worker | `deploy-leaperone-email-worker.yml` |
| MultiPost web, backend, video-stt-worker | `deploy-multipost.yml` |

Domestic releases are unaffected. `leaperone-www-cn` and the 2SOMEone
workflows always use `registry.cn-hongkong.aliyuncs.com`.

## Configuration

| GitHub Secret | Purpose |
| --- | --- |
| `DE_REGISTRY_HOST` | Registry host with an optional port, without scheme or path. Leave unset to keep `registry.cn-hongkong.aliyuncs.com`. |
| `DE_REGISTRY_USERNAME` | Push credential, required when `DE_REGISTRY_HOST` is set. |
| `DE_REGISTRY_PASSWORD` | Push credential, required when `DE_REGISTRY_HOST` is set. |

When `DE_REGISTRY_HOST` is unset, workflows log in with the existing
`ALIYUN_DOCKER_USERNAME` and `ALIYUN_DOCKER_PASSWORD`. The host is a secret so
that GitHub masks it in public logs. For the same reason, job outputs carry
registry-relative image names (`leaperone/leaperone:<tag>`) and bare digests,
and every job that needs the full reference prefixes it with the host from the
secret. Do not set the secret to the Aliyun host or a fragment of it;
workflows reject that because masking would hide domestic image references.

## Deployment contract

- Every overseas deployment pins the manifest digest returned by the push:
  `api-<source-sha>@<digest>`, `www-<source-sha>@<digest>`,
  `dashboard-<source-sha>@<digest>` and `email-worker-<source-sha>@<digest>`.
  MultiPost still publishes `latest`, `backend-latest` and
  `video-stt-worker-latest` for discovery, but deploys `<tag>@<digest>` from
  `component_digests`. A moved tag never changes a running container.
- `deploy-de.yml` exports the selected host as `REGISTRY_HOST` to the remote
  deployment. Compose prefers the exported value over the root `.env`, so a
  stale host in `.env` cannot redirect a pull. RepoDigest checks run against
  the same host.
- The MultiPost deployer records the RepoDigest each selected container
  actually ran before the release. A failed backend or video-stt-worker update
  is restored to that digest from the registry recorded with it. Web keeps
  the previous color stopped for rollback.
- The Email Worker deployer writes `REGISTRY_HOST` to its root `.env`
  together with the image fields. An automatic rollback restores the previous
  host and digest and runs Compose with that host.
- `deploy-leaperone-www` accepts `global_only: "true"` in the dispatch
  payload. The global site is released and the CN variant is left on its
  current image.

## Target prerequisites

- Each deployment target must be logged in to the selected registry before
  the first release from it. Workflows never copy registry credentials to
  deployment targets.
- An image published before the switch exists only on the old registry unless
  it was copied. A manual rollback to such a digest must name that registry.
- Build and deploy jobs stay on GitHub-hosted runners. The repository runner
  policy has no Germany runner label; adding one is an administrative change.
