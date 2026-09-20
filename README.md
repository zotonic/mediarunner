# Media runner

A dedicated Zotonic site that queues and processes media jobs on a separate host.
It uses OAuth2 authentication, native sandboxing where supported, and a persistent
cache so large files only need to be uploaded once while cached.

- **Processing:** ImageMagick, Ghostscript and ffmpeg, with automatic worker capacity
  based on CPU cores and available memory, plus `jobs` overload protection.
- **Transfers:** streamed uploads and downloads, SHA-256 verification, and HTTPS
  callbacks to the originating site. Concurrent jobs share uploads and cached results.
- **Dashboard:** queue status, completion/failure graphs, cache usage and job history.
- **Consumers:** create client accounts, rotate OAuth2 keys and view per-consumer statistics.

## Setup

1. Install this site under `apps_user/mediarunner` in the runner's Zotonic checkout.
2. Install the sandbox helper and required media tools, fonts and ImageMagick policy.
   Use a dedicated host with persistent storage and OS/container resource limits.
3. Configure the hostname, database, TLS and administrator credentials in private
   site configuration, then enable the site. The supplied configuration is disabled
   and contains no credentials.
4. Log in as an administrator and select **Add website / consumer**. Copy the
   generated OAuth2 key; it is shown only once. Use a separate consumer per client
   installation, as cache access is isolated by consumer user.
5. Configure the client as below. Install the `file` utility on clients for local
   MIME detection.

Check `z_exec:sandbox_status/0` before deployment. Unsupported systems continue
**without isolation** and show a prominent alarm to authorized dashboard users.
Missing helpers and other sandbox setup errors block processing. API keys authorize
shell commands within the selected profile: issue them only to trusted clients.

## Connect a Zotonic client

Add these settings to the `zotonic` application section of the client's system
`zotonic.config`, **not** its site configuration:

```erlang
{media_runner_hostname, <<"media.example.com">>},
{media_runner_oauth2_key, <<"YOUR-OAUTH2-BEARER-TOKEN">>},
{media_runner_local_fallback, false}
```

The hostname may include a port; HTTPS and `/media-runner/jobs` are fixed.
Omit `media_runner_hostname` to keep processing local.

Image, audio and video processing use the runner automatically. Custom code uses
`z_exec:run(Profile, Command, Options, Context)` and declares input/output files in
`read` and `write`. Plain `z_exec:run/1,2` commands remain local.

Callbacks use the originating site's `media_runner_callback` dispatch route.
The URL must be reachable from the runner and route to the **submitting Zotonic
node**, including behind a load balancer. Pending calls do not survive a client
node restart.

Optional local fallback covers transport errors, overload and callback timeouts;
authentication and processing failures do not trigger it. Install compatible local
tools if enabling fallback. The client detects the runner's ImageMagick version
and warns when local fallback uses a different major version.

## Configuration and operation

Runner settings belong in the **site configuration**. Common defaults:

| Setting | Default |
| --- | --- |
| `mediarunner_workers` | `auto`, bounded to 1–32 workers |
| `mediarunner_memory_per_worker` | 4 GiB |
| `mediarunner_queue_limit` | 1,000 outstanding jobs |
| `mediarunner_uploads` | 4 upload reservations |
| `mediarunner_cache_max_bytes` | 100 GiB |
| `mediarunner_cache_max_age` | 7 days idle |
| `mediarunner_result_retention` | 24 hours for uncollected outputs |
| `mediarunner_callback_urls` | `any` authenticated caller's valid HTTPS endpoint |

See the [configuration reference](docs/reference.md#queue-and-automatic-capacity)
for exact values, storage budgets and all options. The
[client settings](docs/reference.md#client-system-configuration) include file size,
callback and timeout limits; some must be configured on both hosts.

- **Queue:** jobs persist in PostgreSQL; unfinished processing resumes after restart.
  Callbacks retry with backoff. HTTP 429 indicates overload or insufficient capacity.
- **Cache:** source/result files normally live in
  `<data_dir>/sites/mediarunner/files/mediarunner/`; private job files use
  `mediarunner-work/` alongside it. Budget disk for both. Hourly cleanup reconciles
  files with PostgreSQL and evicts eligible entries. Sandboxed jobs cannot access the shared cache.
- **Result reuse:** successful results are cached by source hashes and operation,
  including tool/profile configuration. Bump `mediarunner_cache_version` after
  changing fonts, ImageMagick policy or other dependencies not detected automatically.
- **Reverse proxy:** allow large streaming PUTs to `/media-runner/jobs/files/:hash`
  and GETs from `/media-runner/jobs/results/:hash`. Disable buffering for these
  routes and allow up to one hour per transfer.
- **TLS:** HTTPS is required and redirects are refused. Certificates are verified
  except when the system `zotonic` environment is `development`.
- **Upgrades:** drain outstanding jobs and upgrade Zotonic and mediarunner together;
  both must support protocol version 3.

The homepage refreshes every ten seconds. Administrators use **Consumers** to rename
accounts, rotate keys, delete consumers and view statistics. Rotation revokes old
keys; renaming preserves them. Consumer accounts are not publicly viewable.

## Tests and CI

After building Zotonic, run the test harness from its checkout root:

```sh
ZOTONIC_DBHOST=localhost ZOTONIC_SANDBOX_TESTS=1 bash apps_user/mediarunner/test/ci.sh
```

Use a development PostgreSQL instance with database/user/password `zotonic`.
The harness uses a disposable `mediarunner_test` schema and temporarily changes the
site configuration. **Do not run it in a checkout serving a live site.**

[GitHub CI](.github/workflows/test.yml) checks out Zotonic, installs this site under
`apps_user`, and runs unit and HTTPS integration tests on Ubuntu with sandboxing
required. Set the repository variable `ZOTONIC_REF` to select a Zotonic branch or
commit, or use `zotonic_ref` for a manual run; the default is `master`.

See the [testing reference](docs/reference.md#verification) for coverage, ports,
large-file tests and fixture details, and the
[cache/protocol reference](docs/reference.md#content-cache) for upload reservations,
result delivery and cleanup behavior.
