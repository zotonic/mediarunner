# Configuration and operations reference

Detailed deployment, configuration, protocol and testing notes. Start with the
[README](../README.md) for setup and an overview.

## Deployment

Install the sandbox helpers and media tools on the runner host, including the
ImageMagick policy, fonts, Ghostscript (for PDFs), ffmpeg and file as needed. Check
`z_exec:sandbox_status/0`. On supported systems, the runner enforces the sandbox even
when the host has `exec_sandbox` set to `disabled`. Unsupported operating systems
or Linux kernels without Landlock ABI 3 log a NOTICE and continue without sandbox
isolation. Timeouts, bounded stdout/stderr and process-group cleanup remain active;
filesystem/network restrictions and sandbox CPU/memory/file-size limits do not.
Missing helpers and other policy setup failures still block processing. Failed
media commands are never retried without isolation.

The homepage shows a prominent red alarm above the queue overview when isolation
is unavailable or setup fails, visible only to logged-in authorized users. When
isolation is available, the dashboard shows the normal sandbox status. Status is probed on startup and
every minute and appears in the dashboard's normal refresh updates. Keep this site
on a dedicated host with OS/container resource limits: sandbox resource limits apply per process,
not to all delegates together.

Configure the hostname, database schema, TLS and administrator credentials in a
private site configuration, then enable the site. The checked-in site is disabled
and contains no credentials. Give API users a writable OAuth2 token and the
`use` permission for `mediarunner`; dashboard users also need that permission.
Authentication uses Zotonic's normal request context: `mod_oauth2` decodes tokens
and logs on the user, retaining token group and read-only restrictions. The endpoint
requires an authenticated, writable context with `use mediarunner` permission;
normal Zotonic session authentication also applies.
Administrators can click **Add website / consumer** on the homepage and enter a
name. This atomically creates a dedicated user, membership in the independent
**Media runner consumers** group, and a writable OAuth2 key restricted to that
group. The group grants only `use mediarunner`, without administration access.
Consumer users are placed in the independent **Private media runner consumers**
content group. Anonymous viewing is explicitly denied; managers can administer the
accounts. Existing consumer accounts are moved into this group on upgrade. Accounts
remain published so OAuth2 authentication works; publication does not grant public
viewing permission. No password is created. Copy the key from the confirmation dialog into the client's
`media_runner_oauth2_key`; the dialog shows it only once. Revoke the key or disable
the client in **OAuth2 clients**. Unpublishing the consumer user also disables access.
The admin-only **Consumers** page lists consumer names and status without exposing
keys. **Update** changes the name; selecting **Generate a new OAuth2 key** revokes
all existing keys for that consumer and displays the replacement for copying.
Renaming alone keeps the current key valid. **Delete** asks for confirmation,
revokes the consumer's keys, and removes its user unless another OAuth2 app or key
still uses it. Existing jobs and cached files follow normal retention. Read-only
administrators can view the list but cannot change consumers.

Use a separate consumer per client installation: cache access is isolated by OAuth
user, not by individual token. Advanced token management remains available in
Zotonic's OAuth2 administration.

By default, authenticated callers may choose any valid HTTPS callback endpoint:
`mediarunner_callback_urls` is `any` (omitting the setting has the same effect).
Optionally restrict callbacks to an explicit list of exact endpoints:

```erlang
{mediarunner_callback_urls, [
    <<"https://www.example.com/media-runner/callback">>
]}.
```

An explicit empty list rejects all callbacks. The policy is checked both when a
job is submitted and before each delivery attempt.

Callbacks must use HTTPS without query parameters, userinfo or fragments. The
runner adds the job ID as a query parameter. TLS certificates are verified except when the system `zotonic` application
configuration sets `{environment, development}`. In development, self-signed
certificates are accepted for job requests, uploads, result downloads and callbacks.
Other environments, including `test`, verify certificates and hostnames using the
normal certificate trust store. HTTPS is required and redirects are
refused in every environment. Permit these outbound destinations in the host firewall.
Media commands themselves have no network access. API credentials authorize shell
commands within the selected sandbox profile; issue them only to trusted clients.

## Consumer statistics

The Consumers page shows cumulative submitted, completed and failed jobs, result-cache
hits, elapsed processing seconds and failed/expired callbacks per consumer user.
Expand **Statistics** for totals. Queue counts, pending callbacks and completed cached
file counts/bytes reflect current usage. Cached bytes count each stored file once;
upload reservations and result-manifest JSON are excluded. Processing time uses the
final execution's start/finish timestamps, excluding cache hits; it is not CPU time
and does not include earlier execution attempts interrupted by a restart.

Cleanup atomically rolls deleted jobs into PostgreSQL totals. Repeated cleanup does
not double-count jobs, and key rotation does not reset statistics. On upgrade, totals
start with the job history still present; previously deleted history is unavailable.
Consumers sharing a user share statistics, just as they share cached files. Statistics
are visible only to administrators, including read-only administrators.

## Client system configuration

Add these entries to the `zotonic` application section in the system
`zotonic.config` (not the site configuration):

```erlang
{media_runner_hostname, <<"media.example.com">>},
{media_runner_oauth2_key, <<"YOUR-OAUTH2-BEARER-TOKEN">>},
{media_runner_local_fallback, false}
```

The client uses HTTPS model APIs for controls and `/media-runner/jobs` for file transfers; do not include a
scheme or path in `media_runner_hostname`. An optional port is supported, for
example `localhost:18443` for testing; the default is HTTPS port 443.
This replaces the former `media_runner_url` setting.

The callback URL is generated by the originating site's dispatcher using the
`media_runner_callback` route from `mod_base` and its canonical absolute URL.
There is no system-wide callback URL setting. Image, audio and video processing
pass their site context, including background jobs. Custom callers should use
`z_exec:run(Profile, Command, Options, Context)`; remote execution without a site
context returns a configuration error. Context-free calls still work when remote
processing is disabled.

The callback must reach the same Zotonic node which submitted the job. Cluster
load balancers must route this endpoint to the submitting node.
Pending client calls are process-monitored and are not persisted across a client
node restart. Late callbacks receive HTTP 410 and stop retrying.

Omitting `media_runner_hostname` retains local execution. Optional settings:

| System setting | Default | Meaning |
| --- | --- | --- |
| `media_runner_wait_timeout` | `3900` | Job expiry and callback wait in seconds (65 minutes); allow for uploads, queuing and processing, and keep below 24 hours. |
| `media_runner_max_input_bytes` | `17179869184` | Maximum source file size (16 GiB); configure on both hosts. Sources are streamed. |
| `media_runner_max_output_bytes` | `17179869184` | Maximum combined output size per job (16 GiB); configure on both hosts. Outputs are streamed. |
| `media_runner_max_callback_bytes` | `135266304` | Maximum encoded callback JSON body (129 MiB), reserved per starting/running job. Configure on both hosts; file transfers have separate limits. |
| `media_runner_local_fallback` | `false` | Retry locally on transport errors, overload, HTTP 502–504 or callback timeout. |

When upgrading from the millisecond setting, divide any configured
`media_runner_wait_timeout` value by 1000; for example, `3900000` becomes `3900`.

Authentication, invalid jobs and processing failures do not trigger local
fallback. Local fallback follows the existing `exec_sandbox` policy and requires
local tools. After an ambiguous network failure the remote job might still run;
processing must tolerate duplicate execution. The client only installs results
from the request it is awaiting.

Media tool discovery works without local binaries when remote processing is
configured. The client probes the authenticated `/api/model/mediarunner_job/get/capabilities`
endpoint for the runner's installed ImageMagick version. The runner executes its
local binary with `-version`; preview and identify commands use that version,
including the differences between ImageMagick 6 and 7. The old
`media_runner_imagemagick_legacy` setting is no longer needed.

Local and remote probes have separate 60-second caches. Hostname, credentials,
TLS configuration and fallback changes invalidate the remote cache; local executable
changes invalidate the local cache. Failed probes retry after five seconds, and
concurrent requests share a refresh. If the runner is unavailable, local discovery
is used only when local fallback is enabled; otherwise preview generation reports a missing
tool rather than guessing a remote version. With local fallback enabled, differing
local/remote major versions (including a missing local installation) log a warning once
per configuration/major-version combination. Align the versions for compatible fallback.
Run `z_media_imagemagick:clear_cache/0` to force immediate rediscovery.

Custom absolute executable paths must exist on the runner. Input and
output files must be explicitly declared in `read` and `write`; paths in commands
are replaced with private workspace paths. The remote working directory is a
private scratch directory. Server profile limits determine CPU/memory permissions;
clients cannot supply filesystem grants. Arbitrary directory access, undeclared
sidecar files and custom local environment variables are not transferred.

## Queue and automatic capacity

Jobs are stored in PostgreSQL before acceptance. A supervised coordinator runs
separate general and ffmpeg render worker pools, each with its own `jobs` counter and
CPU/memory overload modifiers. Rendering defaults to one worker; set
`mediarunner_ffmpeg_workers` to `2` for two concurrent renders. ImageMagick, ffprobe,
file and `ffmpeg_preview` jobs use the general pool and skip queued renders.
Video thumbnails and audio artwork extraction use `ffmpeg_preview` automatically.
Custom lightweight callers can use `z_exec:run(ffmpeg_preview, Command, Options, Context)`;
full conversions should retain `ffmpeg`. Both profiles use the same ffmpeg sandbox
limits and administrator-configured grants. The distinction is explicit, not
inferred from shell command text. Upgrade the Zotonic code on both client and
runner before using the new profile; older runners reject it.
On restart, unfinished processing jobs are queued again. Two separate callback
workers keep delivery moving while processing is saturated. Failed callbacks retry
with exponential delays, up to 12 attempts or the job deadline. Job history is
retained for seven days; callback credentials and result payloads are removed once
delivery finishes or expires.

The default queue accepts up to 1,000 outstanding jobs to accommodate thumbnail
batches. Waiting jobs consume their actual metadata size; only starting/running
jobs reserve a maximum callback envelope. Admission keeps room for another worker,
and processing pauses when result storage is full until callbacks free space.
Worker concurrency and overload protection remain independently bounded.

These settings belong to the runner **site** configuration:

| Site setting | Default | Meaning |
| --- | --- | --- |
| `mediarunner_workers` | `auto` | General pool capacity, or an explicit integer from 1 to 32. |
| `mediarunner_ffmpeg_workers` | `1` | Separate ffmpeg render pool: 1 or 2 workers; other values use 1. |
| `mediarunner_memory_per_worker` | `4294967296` | Memory budget per processing worker (4 GiB). |
| `mediarunner_queue_limit` | `1000` | Maximum outstanding jobs, including callback delivery. |
| `mediarunner_storage_limit` | `1073741824` | Queue metadata and result budget, including reserved space for starting/running results. |
| `mediarunner_uploads` | `4` | Maximum concurrent upload reservations. |
| `mediarunner_cache_max_bytes` | `107374182400` | Combined disk source/result cache budget (100 GiB), including reserved uploads. |
| `mediarunner_cache_max_age` | `604800` | Expire unpinned files and cached manifests after this many idle seconds (seven days; minimum one hour). |
| `mediarunner_result_retention` | `86400` | Seconds to protect uncollected outputs after processing (24 hours, checked hourly). |
| `mediarunner_cache_version` | `1` | Administrator-controlled result-cache generation. |

Automatic general workers are `max(1, min(32, cores - 1, floor(available_memory * 0.75 /
memory_per_worker)))`. Online Erlang schedulers and detected Linux cgroup CPU and
memory quotas bound the calculation. Memory comes from `memsup`, including
reclaimable cache where reported. If memory information is unavailable the default
is one worker. Capacity is refreshed every minute; running work is allowed to
finish when the limit decreases. `jobs` may further delay admission under load.
An explicit worker count overrides the calculation, but retains overload protection.
The ffmpeg workers are additional to the general worker count; budget host resources
for both pools. Changes take effect within a minute and allow running work to finish.
CPU/memory overload can still throttle either pool. Before starting ffmpeg, the
scheduler leaves one callback envelope free for general work, so renders cannot
consume the entire execution reservation budget.

The storage budget is separate from the cache budget and is conservative: reserving
space for worst-case results may reject work before the job-count limit is reached.
HTTP 429 indicates overload or insufficient cache capacity. Configure the reverse
proxy to allow `media_runner_max_input_bytes` on `PUT /media-runner/jobs/files/:hash`
and disable request buffering for that route (for example, `proxy_request_buffering off`
in nginx). Allow up to one hour for an upload. Job JSON is limited to 1 MiB.
Callbacks contain only result metadata and bounded base64 stdout. Output files are
streamed separately over authenticated HTTPS; allow up to one hour per download and
disable proxy response buffering on `GET /media-runner/jobs/results/:hash`.
`media_runner_max_callback_bytes` is the actual callback JSON body limit in bytes;
no encoding multiplier or additional allowance is applied. It replaces
`media_runner_max_bytes`; to preserve an explicitly configured old limit, use
`2 * old_value + 1048576`. The effective default is unchanged.

The Zotonic client runs `file --mime-type` locally without sandboxing, so install
the `file` utility on clients as well. MIME sniffing does not upload the source.
Image inspection and media processing continue through the sandboxed runner.

## Content cache

The client hashes source files incrementally using `z_crypto:hex_sha2_file/1` and submits only SHA-256 hashes,
sizes and file metadata. No source bytes or client filesystem paths appear in job
JSON. The `submit` model operation returns the `missing` outcome and source hashes. For each missing hash:

1. `model/mediarunner_job/post/reserve` with `{"hash": sha256, "size": bytes}` reserves capacity.
   Outcome `present` means no upload is needed. Outcome `upload` includes an
   `upload_token`. Outcome `busy` means another request owns the reservation;
   the client waits and checks again instead of uploading a duplicate. If the
   upload fails, a waiting client can reserve the hash and take over with a fresh
   token. Late cleanup using an old token cannot remove the replacement upload.
2. Only the reservation holder sends `PUT /media-runner/jobs/files/:hash` with an
   `application/octet-stream` body, `Content-Length`, and `X-Upload-Token`.
   Both requests require the regular OAuth2 bearer token and mediarunner permission.
3. The runner streams into a private disk file, verifies its exact size and SHA-256,
   and makes it visible atomically through the cache metadata. HTTP 204 confirms
   publication. Truncated, corrupt and failed uploads are removed. Unclaimed reservations
   expire after one minute; active uploads have one hour. The queue monitors the
   active PUT request and releases its reservation immediately if the request dies.
   Restart invalidates unfinished uploads.
4. The client resubmits the hash-only job. Later operations reuse the uploaded
   source without sending its bytes again. An LRU eviction requires a new upload.

Cache paths use `z_path:files_subdir_ensure/2`, which follows the configured
`data_dir`. Its default comes from `z_config_files:data_dir/0`. For the
`mediarunner` site, the paths are:

- Cached source and result files: `<data_dir>/sites/mediarunner/files/mediarunner/`
- Temporary job files: `<data_dir>/sites/mediarunner/files/mediarunner-work/`

On macOS the OS default data directory is
`~/Library/Application Support/zotonic/`. An explicit `data_dir`,
`ZOTONIC_DATA_DIR`, or an existing local `data` directory can select another location.
Legacy sites with an existing `priv/files` directory use that directory instead.
Paths containing spaces are supported and exercised by the integration suite.

Source and output files live under the site's persistent `files/mediarunner` directory; PostgreSQL
stores file metadata and bounded result manifests. Reserve disk capacity for both this
cache and workers' private input copies and output files. Mount the site's data
folder on persistent storage. The hash-only envelope is protocol version 3. Drain outstanding jobs and upgrade
both Zotonic and mediarunner together; older protocol versions are rejected.

On supported systems, sandboxed commands receive access only to individual input/output files staged in
a private job directory, plus their sandbox scratch space and required tool/runtime
files. The cache directory and cached originals are never granted to the sandbox.
Inputs are copied, not hard-linked, so commands that overwrite their inputs cannot
modify shared cache entries.

Successful callbacks describe each output with its file ID, byte size, SHA-256 and
an authenticated download URL. No output bytes are embedded in JSON. The client
uses its OAuth2 bearer token and accepts URLs only on the exact configured runner
result endpoint. It streams into private temporary files, verifies sizes and hashes,
and only then replaces the requested local outputs. A failed download leaves the
existing outputs intact. Each result file has a content hash; the operation cache
key described below is separate.

`model/mediarunner_job/post/received` with `{"id": job_id}` acknowledges successful collection
and releases the output pins. Receiving the callback alone does not release them.
Abandoned downloads remain protected for `mediarunner_result_retention`; after that
they become eligible for LRU eviction. Cached operation manifests are reused only
while every referenced output blob still exists; otherwise the job runs again.
Downloads and receipts require the submitting OAuth user's identity and permission.

Accepted jobs pin their inputs until processing finishes. Recently accessed sources
also have a one-hour eviction grace period to cover the gap between uploads and job
admission. Sources, results and upload reservations share a budget of bytes and
10,000 entries. HTTP 429 is returned when protected entries leave insufficient space.
Cache contents are private to the OAuth user and can outlive an individual job.
Eviction rechecks access times and job pins when deleting each candidate. Result
publication uses worker capacity independently of incoming upload slots, while
still obeying the shared disk and entry budgets.

Control messages use `z_fetch:fetch_json` and the standard model API:

| Model operation | Payload | Result |
| --- | --- | --- |
| `mediarunner_job/get/capabilities` | `{}` | Installed ImageMagick details |
| `mediarunner_job/post/submit` | Job manifest | `accepted`, `missing`, or failure outcome |
| `mediarunner_job/post/reserve` | `hash`, `size` | `present`, `upload` with token, or `busy` |
| `mediarunner_job/post/received` | Job `id` | `received` |

HTTP URLs prefix these operations with `/api/model/`; MQTT topics prefix them with
`model/`. HTTP clients unwrap the standard `status`/`result` model envelope.
Authorization and validation live in the model for both transports. Client and runner
must be upgraded together when switching from the old controller protocol.

OTP `httpc` streams file uploads and successful result downloads; size/hash checks
protect publication. Trusted peers' small JSON/error responses are buffered, with
control responses limited by the fetcher's 64 KiB setting. Redirects are disabled.
File transfers use dedicated connections outside httpc's persistent-session queues;
JSON uses z_url_fetch's separate pool (ten sessions per host). Large transfers
therefore cannot block control requests. Downloads have an absolute deadline and request cancellation.
TLS uses normal certificate trust, with verification disabled only in development;
server certificates remain managed by Zotonic's SSL modules.

The result key hashes source hashes, normalized command/parameters, file extensions,
profile, timeout and protocol version, together with execution code, tool stamps,
server profile configuration, transfer limits and `mediarunner_cache_version`.
Job IDs, callbacks and deadlines do not affect reuse. A change of source or operation
produces a different key. Tool stamps use executable path, modification time and
size. Bump `mediarunner_cache_version` after changing fonts, ImageMagick policy,
external assets or tool dependencies which do not change the executable stamp.
On startup and hourly, the queue reconciles the disk cache with PostgreSQL in
small batches, allowing uploads and job requests between batches. It removes
expired unpinned entries, metadata for missing/non-regular/wrong-size files, and
result manifests whose output blobs are no longer registered. It also removes
unregistered disk files older than one hour. Active upload reservations, recently
accessed files and job pins remain protected. Result pins survive runner restarts.
This checks file presence, type and size; it does not rehash multi-gigabyte files
on every sweep. Transfer-time SHA-256 checks still verify contents.

Private staging directories live in `files/mediarunner-work/:job-id.:random-id`.
Normal completion removes them immediately. Periodic cleanup cross-references
them with the job table and removes directories older than one hour when their
job is no longer starting/running. Cleanup never follows symlinks out of either
managed directory. It logs removal counts and filesystem errors; filesystem
reconciliation retries any files left behind by a failed deletion. Schema version
4 adds a path index for these lookups.

Only successful results are cached. Operations should be deterministic; commands
using time or randomness need an explicit varying command parameter or cache-version
change to avoid reuse.

## Dashboard

Log in at the site root for queue/running/completed counts, hourly completion and
failure graphs rendered by the SVG chart scomp (hours in UTC), callback delivery status, cache capacity and a filterable job list.
It refreshes every ten seconds, can be paused, and retains the last snapshot with
a visible warning when refresh fails. Charts include a tabular alternative. The
model enforces the same permission as the page and never exposes media, commands,
OAuth keys or callback credentials.

## Verification

`z_media_runner_tests` covers protocol boundaries, path rewriting, callback
ownership and output validation. Set `ZOTONIC_SANDBOX_TESTS=1` to include a real
sandboxed image roundtrip. `mediarunner_tests` covers request validation and capacity
calculations. Compile the project and run both modules with EUnit.

`mediarunner_integration_tests:run/0` is an explicit development fixture for a
**disposable** site named `mediarunner`, with schema `mediarunner_test`, HTTPS on
localhost:18443 and a test CA/server certificate under `/tmp/zmr-tls`. It refuses a
different schema. It exercises OAuth rejection, sandbox processing, callbacks,
restart recovery, idempotency, cache eviction/isolation/integrity and opt-in local
fallback. Do not point it at a deployed runner.

### GitHub Actions

The workflow in `.github/workflows/test.yml` runs on pushes, pull requests and
manual dispatches in the standalone `zotonic/mediarunner` repository. It checks out
`zotonic/zotonic`, then checks out this repository directly into
`zotonic/apps_user/mediarunner`. GitHub only discovers the workflow once this site
is the repository root; it does not run from the nested directory in Zotonic.

CI installs OTP 28.5 directly on Ubuntu 24.04, with PostgreSQL 16 in a service
container. It logs the host OS, builds Zotonic and the site together, then runs
the unit tests (including native sandbox tests) and full HTTPS integration suite
as the unprivileged GitHub runner user, preserving access to the checkout and
setup-beam installation. A non-root check precedes the tests. Sandbox enforcement is required: unavailable Landlock or
sandbox helpers fail the run. ImageMagick 6 and 7 are both supported by the
integration fixture. The unsupported-platform unit test deliberately simulates
FreeBSD; its fallback NOTICE describes the mocked OS, not the actual CI runner.
No production credentials or repository secrets are needed.

The Zotonic ref defaults to `master`. Set the repository variable `ZOTONIC_REF`
for push/PR builds, or supply `zotonic_ref` when starting a manual run. The selected
ref must include the protocol-v3 streaming upload/download client, callback controller and SVG chart scomp;
until these changes are merged, select the branch or commit containing them.

To run the same checks locally after building Zotonic:

```sh
ZOTONIC_DBHOST=localhost ZOTONIC_SANDBOX_TESTS=1 bash apps_user/mediarunner/test/ci.sh
```

The integration suite uploads a 70 MiB source by default. Set
`MEDIARUNNER_TEST_UPLOAD_BYTES=2147483649` to exercise a source larger than 2 GiB.
It verifies cache reuse without another upload, size/hash validation, OAuth isolation,
reservation expiry and partial-file cleanup. Concurrent-job tests cover a successful
upload, corrupt content, a killed uploader and an expired claim.

It also renders and downloads a 72 MiB ffmpeg result, checks authenticated access,
small callback manifests, result cache reuse, receipt pin release and invalidation
when an output blob disappears. Set `MEDIARUNNER_TEST_RESULT_FRAMES=1366` to render
a result larger than 2 GiB. Corrupt downloads and unexpected download hosts are
covered by the client unit tests.

Use a development PostgreSQL instance with database/user/password `zotonic`.
The harness uses the **disposable** `mediarunner_test` schema, loopback ports
18080/18443/18252/18883/18884, temporary data/configuration and a generated test CA.
It temporarily changes the site's configuration, restores it on exit, and stops
its Erlang VM when finished. Do not run it in a checkout serving a live site.
The test schema remains available for subsequent test runs.
