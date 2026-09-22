# A pool of media runners

Configure independent runners in the **client's system configuration**:

```erlang
{media_runners, [
    #{hostname => <<"media-a.example.com">>, oauth2_key => <<"TOKEN-A">>},
    #{hostname => <<"media-b.example.com">>, oauth2_key => <<"TOKEN-B">>}
]}.
```

Create a consumer on each runner and use its token for that entry. Each runner
keeps its own database, queue and disk cache. Do not share a database schema or
place round-robin HTTP routing in front of independent caches.

The pool replaces `media_runner_hostname` and `media_runner_oauth2_key` when set.
An empty pool disables remote processing. Without this setting, the existing
single-runner configuration continues to work. At most 32 entries are accepted;
invalid entries reject the configuration instead of silently enabling local work.

## Selection and cache reuse

The client hashes inputs once before selecting a runner. It prefers runners
expected to have the most input bytes cached, then runners with fewer jobs from
this client in the relevant worker pool. FFmpeg renders are counted separately
from general jobs, including FFmpeg previews. Deterministic hashing distributes
cold inputs across runners; jobs without inputs use a fresh tie-breaker.

Selection and recording expected input locations happen atomically. In-flight
jobs count as expected file locations, so concurrent requests prefer waiting on
the same upload lease even when other jobs change the activity counts. Successful uploads, accepted inputs and
successfully downloaded outputs teach the client where files are cached. A subsequent command using an output as input
therefore prefers that same runner, even if the local file has been renamed.
Hints expire after one hour and are capped at 10,000 entries per client Erlang
node. They are scoped by endpoint and OAuth2 credential and disappear on a client
restart. Changing credentials starts fresh hints.

Hints are advisory: the existing hash-only submission checks actual availability.
A cache miss removes the stale hint and uploads only the missing file. Concurrent
uploads on the chosen runner still use its existing upload lease.

Activity counts reflect this client node, not a cluster-wide load measurement.
Each runner's queue admission and `jobs` overload protection remain authoritative.
A full or unreachable runner is avoided for five seconds by new jobs.

## Failover

Each attempt owns its endpoint, OAuth2 credential, job ID and callback secret.
Uploads, downloads and result receipts all use that endpoint. Unavailable runners
and admission refusals are retried on the remaining eligible pool members.
Connection failures during result downloads also allow another attempt; partial
downloads are removed before retrying. Admission authentication errors, invalid
results (including incorrect hashes) and command-processing errors are returned
directly.

If a submission response is lost, the client first checks whether that runner
accepted the job. After acceptance, callbacks remain the normal completion path.
An authenticated `mediarunner_job/post/status` lookup every 15 seconds recovers a
lost callback. Three consecutive failed status probes allow another attempt.
Upgrade runners to a version providing this lookup before enabling the pool.

Replacement attempts reject late callbacks from their predecessors. A network
partition can still cause duplicate computation on independent runners; there is
no distributed exactly-once execution or cancellation guarantee. Completed files
and abandoned attempts are reclaimed by normal receipt/expiry cleanup.

`media_runner_wait_timeout` is one overall remote waiting budget, in seconds,
shared by attempts. Individual HTTP operations have their own timeouts and can
extend the observed duration. If configured, local fallback follows exhaustion of
remote alternatives. Processing errors do not trigger fallback.

## Tool versions

Use matching tool installations across the pool. The client probes up to 32 runners concurrently with a shared 5.5-second
deadline. The complete capability snapshot is cached for 60 seconds, or 5 seconds
if any probe fails. The retry period starts after discovery completes, so slow
hosts cannot expire earlier failures while other probes are still running. ImageMagick command generation selects the most common major version among
available installations. Ties follow configuration order; missing or unreachable
installations do not vote. ImageMagick jobs are restricted to that majority group
and the selected command (`magick` or `convert`). Minor and patch differences do
not split the group. The choice is recalculated from the cached capabilities and
can change for new commands when those capabilities refresh. Previews and
identification pin the major version and executable used during argument
generation; an already-built command keeps these requirements when selecting or
retrying a runner. Custom ImageMagick callers can pass the same snapshot in the
`media_runner_imagemagick` execution option, with `major` and `tool` keys. Other tools must be provisioned consistently by the
operator; the pool does not translate command arguments between tool versions.
