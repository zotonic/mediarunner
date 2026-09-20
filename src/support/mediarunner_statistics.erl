%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Preserve per-consumer job totals and report current queue and cache usage.
%% @end

%% Copyright 2026 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mediarunner_statistics).

-moduledoc "Statistics are keyed by the consumer user, like jobs and cached files.
Archived totals and live jobs are read in one SQL snapshot. Cleanup atomically moves
deleted jobs into totals, so retries, restarts and concurrent reads cannot count a
job twice or lose it. Only the admin consumer model exposes these statistics.".

-export([install/1, archive/2, snapshot/1]).

-spec install(z:context()) -> ok.
install(Context) ->
    z_db:q("create table if not exists mediarunner_consumer_totals ("
        "owner_id integer primary key, submitted bigint not null, completed bigint not null, "
        "failed bigint not null, cache_hits bigint not null, processing_seconds bigint not null, "
        "callback_failures bigint not null, last_job bigint not null)", Context),
    ok.

%% @doc Archive exactly the rows deleted by cleanup in the same atomic SQL statement.
-spec archive(integer(), z:context()) -> ok.
archive(Before, Context) ->
    z_db:q("with removed as (delete from mediarunner_job "
        "where created < $1 and payload is null returning *) "
        "insert into mediarunner_consumer_totals "
        "(owner_id, submitted, completed, failed, cache_hits, processing_seconds, callback_failures, last_job) "
        ++ totals("removed") ++
        " on conflict (owner_id) do update set "
        "submitted=mediarunner_consumer_totals.submitted+excluded.submitted, "
        "completed=mediarunner_consumer_totals.completed+excluded.completed, "
        "failed=mediarunner_consumer_totals.failed+excluded.failed, "
        "cache_hits=mediarunner_consumer_totals.cache_hits+excluded.cache_hits, "
        "processing_seconds=mediarunner_consumer_totals.processing_seconds+excluded.processing_seconds, "
        "callback_failures=mediarunner_consumer_totals.callback_failures+excluded.callback_failures, "
        "last_job=greatest(mediarunner_consumer_totals.last_job,excluded.last_job)", [Before], Context),
    ok.

%% Processing time is elapsed wall time of the final execution, not CPU time.
%% Cache hits and jobs that never started contribute no execution time.
totals(Table) ->
    "select owner_id, count(*) as submitted, "
    "count(*) filter (where status='completed') as completed, "
    "count(*) filter (where status='failed') as failed, "
    "count(*) filter (where cache_hit) as cache_hits, "
    "coalesce(sum(case when not cache_hit and started is not null and finished is not null "
    "then greatest(0,finished-started) else 0 end),0)::bigint as processing_seconds, "
    "count(*) filter (where delivery in ('failed','expired')) as callback_failures, "
    "max(created) as last_job from " ++ Table ++ " group by owner_id".

%% @doc Read all owners in one query, avoiding one database query per consumer.
-spec snapshot(z:context()) -> map().
snapshot(Context) ->
    {ok, Rows} = z_db:qmap(
        "with history as (" ++ totals("mediarunner_job") ++
        " union all select * from mediarunner_consumer_totals), "
        "totals as (select owner_id, sum(submitted)::bigint as submitted, "
        "sum(completed)::bigint as completed, sum(failed)::bigint as failed, "
        "sum(cache_hits)::bigint as cache_hits, sum(processing_seconds)::bigint as processing_seconds, "
        "sum(callback_failures)::bigint as callback_failures, max(last_job) as last_job "
        "from history group by owner_id), "
        "queue as (select owner_id, count(*) filter (where status in ('queued','starting')) as queued, "
        "count(*) filter (where status='running') as running, "
        "count(*) filter (where delivery in ('pending','sending')) as callbacks_pending "
        "from mediarunner_job group by owner_id), "
        "cache as (select owner_id, count(*) as cached_files, sum(size)::bigint as cached_bytes "
        "from mediarunner_cache where kind='file' and complete group by owner_id), "
        "owners as (select owner_id from totals union select owner_id from cache) "
        "select owner_id, coalesce(submitted,0) as submitted, coalesce(completed,0) as completed, "
        "coalesce(failed,0) as failed, coalesce(cache_hits,0) as cache_hits, "
        "coalesce(processing_seconds,0) as processing_seconds, "
        "coalesce(callback_failures,0) as callback_failures, last_job, "
        "coalesce(queued,0) as queued, coalesce(running,0) as running, "
        "coalesce(callbacks_pending,0) as callbacks_pending, "
        "coalesce(cached_files,0) as cached_files, coalesce(cached_bytes,0) as cached_bytes "
        "from owners left join totals using (owner_id) left join queue using (owner_id) "
        "left join cache using (owner_id)", Context),
    maps:from_list([{maps:get(<<"owner_id">>, Row), maps:remove(<<"owner_id">>, Row)} || Row <- Rows]).
