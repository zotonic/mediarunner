%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Persist job admission, processing and delivery state, recovery and dashboard queries.
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

-module(mediarunner_store).

-compile({no_auto_import, [now/0]}).
-moduledoc("
Durable queue storage. Payloads and callback credentials are never included in dashboard
queries. Single active queue coordinator per site database.
").
-export([
    install/1,
    install_cache/1,
    enqueue/3,
    recover/1,
    next/2,
    started/2,
    defer/2,
    result/3, result/4,
    delivered/3,
    failed/3,
    snapshot/2,
    cleanup/1
]).

-spec install(z:context()) -> ok.
install(Context) ->
    z_db:q(
        "create table if not exists mediarunner_job (\n"
        "        id varchar(64) primary key,\n"
        "        owner_id integer not null,\n"
        "        profile varchar(32) not null,\n"
        "        status varchar(16) not null default 'queued',\n"
        "        delivery varchar(16) not null default 'waiting',\n"
        "        request_hash bytea not null,\n"
        "        payload text,\n"
        "        result text,\n"
        "        callback_url text,\n"
        "        callback_token text,\n"
        "        created bigint not null,\n"
        "        started bigint,\n"
        "        finished bigint,\n"
        "        delivered_at bigint,\n"
        "        expires bigint not null,\n"
        "        attempts integer not null default 0,\n"
        "        next_attempt bigint not null default 0,\n"
        "        cache_hit boolean not null default false,\n"
        "        error varchar(80)\n"
        "    )",
        Context
    ),
    z_db:q("create index if not exists mediarunner_job_queue on mediarunner_job(status, created)", Context),
    z_db:q(
        "create index if not exists mediarunner_job_delivery on mediarunner_job(delivery, next_attempt)", Context
    ),
    z_db:q(
        "alter table mediarunner_job add column if not exists cache_hit boolean not null default false",
        Context
    ),
    ok = install_cache(Context),
    mediarunner_statistics:install(Context).

-spec install_cache(z:context()) -> ok.
install_cache(Context) ->
    z_db:q(
        "create table if not exists mediarunner_cache (\n"
        "        owner_id integer not null, kind varchar(8) not null, hash varchar(64) not null,\n"
        "        data bytea not null, size bigint not null, used bigint not null,\n"
        "        primary key (owner_id,kind,hash))",
        Context
    ),
    %% Source bytes live on disk; PostgreSQL holds metadata and upload reservations.
    z_db:q("alter table mediarunner_cache add column if not exists path text", Context),
    z_db:q("alter table mediarunner_cache add column if not exists complete boolean not null default true", Context),
    z_db:q("alter table mediarunner_cache add column if not exists upload_token varchar(64)", Context),
    z_db:q("alter table mediarunner_cache add column if not exists upload_expires bigint", Context),
    z_db:q("alter table mediarunner_cache add column if not exists upload_started boolean not null default false", Context),
    z_db:q("create index if not exists mediarunner_cache_path on mediarunner_cache(path) where path is not null", Context),
    z_db:q("create index if not exists mediarunner_cache_lru on mediarunner_cache(used)", Context),
    z_db:q(
        "create table if not exists mediarunner_job_file (\n"
        "        job_id varchar(64) references mediarunner_job(id) on delete cascade,\n"
        "        owner_id integer not null, hash varchar(64) not null, primary key(job_id,hash))",
        Context
    ),
    z_db:q(
        "create index if not exists mediarunner_job_file_hash on mediarunner_job_file(owner_id,hash)",
        Context
    ),
    ok.

-spec enqueue(map(), integer(), z:context()) -> {ok, binary()} | {error, term()}.
enqueue(Job, Owner, Context) ->
    Id = maps:get(<<"id">>, Job),
    Payload = z_json:encode(mediarunner_cache:strip(Job)),
    Hash = crypto:hash(sha256, Payload),
    case z_db:q("select owner_id, request_hash from mediarunner_job where id=$1", [Id], Context) of
        [{Owner, Hash}] ->
            {ok, Id};
        [_] ->
            {error, conflict};
        [] ->
            {Count, Used} = queue_usage(Context),
            Max = setting(mediarunner_queue_limit, 1000, Context),
            Budget = setting(mediarunner_storage_limit, 1073741824, Context),
            %% Waiting jobs consume only their metadata. Leave room for one more
            %% execution so a full queue cannot prevent its own workers starting.
            Required = Used + byte_size(Payload) + z_media_runner_protocol:callback_limit(),
            case Count < Max andalso Required =< Budget of
                false ->
                    {error, full};
                true ->
                    case mediarunner_cache:prepare(Job, Owner, Context) of
                        ok ->
                            z_db:transaction(
                                fun(Tx) ->
                                    1 = z_db:q(
                                        "insert into mediarunner_job\n"
                                        "                        (id,owner_id,profile,request_hash,payload,callback_url,callback_token,created,expires)\n"
                                        "                        values ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
                                        [
                                            Id,
                                            Owner,
                                            maps:get(<<"profile">>, Job),
                                            Hash,
                                            Payload,
                                            maps:get(<<"callback_url">>, Job),
                                            maps:get(<<"callback_token">>, Job),
                                            now(),
                                            maps:get(<<"expires">>, Job)
                                        ],
                                        Tx
                                    ),
                                    ok = mediarunner_cache:pin(Id, Job, Tx),
                                    {ok, Id}
                                end,
                                Context
                            );
                        {error, _} = Error ->
                            Error
                    end
            end
    end.

-spec recover(z:context()) -> ok.
recover(Context) ->
    %% Completed jobs retain their output pins across restarts until receipt or expiry.
    z_db:q(
        "update mediarunner_job set status='queued', started=null where status in ('starting','running')",
        Context
    ),
    z_db:q("update mediarunner_job set delivery='pending' where delivery='sending'", Context),
    ok.

-spec next(run | ffmpeg | deliver, z:context()) -> none | {run | ffmpeg | deliver, map()}.
next(deliver, Context) ->
    case
        z_db:qmap(
            "update mediarunner_job set delivery='sending', attempts=attempts+1\n"
            "        where id=(select id from mediarunner_job where delivery='pending' and next_attempt <= $1\n"
            "            order by next_attempt,created limit 1) returning *",
            [now()],
            Context
        )
    of
        {ok, [Job]} -> {deliver, Job};
        {ok, []} -> none
    end;
next(Kind, Context) when Kind =:= run; Kind =:= ffmpeg ->
    {_Count, Used} = queue_usage(Context),
    Budget = setting(mediarunner_storage_limit, 1073741824, Context),
    %% Video renders must leave a callback envelope available for general work.
    Reservations = case Kind of ffmpeg -> 2; run -> 1 end,
    case Used + Reservations * z_media_runner_protocol:callback_limit() =< Budget of
        true -> next_run(Kind, Context);
        false -> none
    end.

%% All admissions and dispatches run through the single queue coordinator.
%% Starting/running jobs reserve their maximum result until result/4 replaces
%% that reservation with the actual stored callback envelope.
queue_usage(Context) ->
    [{Count, Bytes, Active}] = z_db:q(
        "select count(*), coalesce(sum(octet_length(payload) + "
        "coalesce(octet_length(result),0)),0), "
        "count(*) filter (where status in ('starting','running')) "
        "from mediarunner_job where payload is not null", Context),
    {Count, Bytes + Active * z_media_runner_protocol:callback_limit()}.

next_run(Kind, Context) ->
    case
        z_db:qmap(
            "update mediarunner_job set status='starting'\n"
            "        where id=(select id from mediarunner_job where status='queued'\n"
            "            and (profile='ffmpeg')=$1\n"
            "            order by created,id limit 1) returning *",
            [Kind =:= ffmpeg], Context
        )
    of
        {ok, [Job]} -> {Kind, Job};
        {ok, []} -> none
    end.

-spec started(binary(), z:context()) -> ok.
started(Id, Context) ->
    z_db:q(
        "update mediarunner_job set status='running',started=$2 where id=$1", [Id, now()], Context
    ),
    ok.

-spec defer(binary(), z:context()) -> ok.
defer(Id, Context) ->
    z_db:q("update mediarunner_job set status='queued',started=null where id=$1", [Id], Context),
    ok.

-spec result(binary(), map(), z:context()) -> ok.
result(Id, Result, Context) -> result(Id, Result, false, Context).

-spec result(binary(), map(), boolean(), z:context()) -> ok.
result(Id, Result, Cached, Context) ->
    {Status, Error} =
        case Result of
            #{<<"status">> := <<"ok">>} -> {<<"completed">>, undefined};
            #{<<"error">> := Why} -> {<<"failed">>, Why}
        end,
    %% Publish the callback and replace input pins in the same transaction.
    ok = z_db:transaction(fun(Ctx) ->
        ok = mediarunner_cache:release(Id, Ctx),
        ok = mediarunner_cache:pin(Id, #{<<"files">> => maps:get(<<"files">>, Result, [])}, Ctx),
        1 = z_db:q(
            "update mediarunner_job set status=$2,result=$3,error=$4,finished=$5,"
            "delivery='pending',next_attempt=$5,payload='{}',cache_hit=$6 where id=$1",
            [Id, Status, z_json:encode(Result), Error, now(), Cached], Ctx),
        ok
    end, Context).

-spec delivered(binary(), term(), z:context()) -> ok.
delivered(Id, {ok, Code}, Context) when Code >= 200, Code < 300 ->
    finish_delivery(Id, <<"delivered">>, Context);
delivered(Id, {ok, 410}, Context) ->
    finish_delivery(Id, <<"expired">>, Context);
delivered(Id, _, Context) ->
    [{Attempts, Expires}] = z_db:q(
        "select attempts,expires from mediarunner_job where id=$1", [Id], Context
    ),
    case Attempts >= 12 orelse now() > Expires of
        true ->
            finish_delivery(Id, <<"failed">>, Context);
        false ->
            Delay = min(3600, 5 * (1 bsl min(Attempts, 10))),
            z_db:q(
                "update mediarunner_job set delivery='pending',next_attempt=$2 where id=$1",
                [Id, now() + Delay],
                Context
            ),
            ok
    end.
finish_delivery(Id, Status, Context) ->
    z_db:q(
        "update mediarunner_job set delivery=$2,payload=null,result=null,\n"
        "        callback_token=null,callback_url=null,delivered_at=$3 where id=$1",
        [Id, Status, now()],
        Context
    ),
    ok.

-spec failed(binary(), run | ffmpeg | deliver, z:context()) -> ok.
failed(Id, Kind, Context) when Kind =:= run; Kind =:= ffmpeg ->
    case z_db:q1("select status from mediarunner_job where id=$1", [Id], Context) of
        Status when Status =:= <<"starting">>; Status =:= <<"running">> ->
            result(Id, #{<<"status">> => <<"error">>, <<"error">> => <<"worker_failed">>}, Context);
        _ ->
            ok
    end;
failed(Id, deliver, Context) ->
    delivered(Id, {error, worker_failed}, Context).

-spec snapshot(binary(), z:context()) -> map().
snapshot(Filter, Context) ->
    {ok, Counts} = z_db:qmap(
        "select case when status='starting' then 'queued' else status end as status,count(*) as count from mediarunner_job\n"
        "        where finished >= $1 or status in ('queued','starting','running') group by 1",
        [now() - 86400],
        Context
    ),
    {ok, Delivery} = z_db:qmap(
        "select delivery,count(*) as count from mediarunner_job\n"
        "        where delivered_at >= $1 or delivery in ('waiting','pending','sending') group by delivery",
        [now() - 86400],
        Context
    ),
    {ok, Hourly} = z_db:qmap(
        "select (finished/3600)*3600 as hour,\n"
        "        count(*) filter (where status='completed') as completed,\n"
        "        count(*) filter (where status='failed') as failed\n"
        "        from mediarunner_job where finished >= $1 group by hour order by hour",
        [now() - 86400],
        Context
    ),
    {ok, Jobs} = z_db:qmap(
        "select id,profile,status,delivery,created,started,finished,attempts,error,cache_hit\n"
        "        from mediarunner_job where ($1 = '' or status=$1 or delivery=$1 or ($1='queued' and status='starting'))\n"
        "        order by case when status in ('queued','starting','running') then 0\n"
        "            when delivery in ('pending','sending','failed') then 1 else 2 end, created desc limit 100",
        [Filter],
        Context
    ),
    #{
        counts => Counts,
        delivery => Delivery,
        hourly => Hourly,
        jobs => Jobs,
        updated => now(),
        workers => maps:get(workers, capacity(Context)),
        capacity => capacity(Context),
        queue_limit => setting(mediarunner_queue_limit, 1000, Context),
        cache => mediarunner_cache:stats(Context)
    }.

-spec cleanup(z:context()) -> ok.
cleanup(Context) ->
    z_db:q("delete from mediarunner_job_file where job_id in "
        "(select id from mediarunner_job where finished < $1)",
        [now() - setting(mediarunner_result_retention, 86400, Context)], Context),
    ok = mediarunner_statistics:archive(now() - 604800, Context),
    ok.
capacity(Context) ->
    case m_site:get(mediarunner_capacity, Context) of
        undefined -> mediarunner_capacity:snapshot(Context);
        V -> V
    end.
setting(Key, Default, Context) ->
    case m_site:get(Key, Context) of
        undefined -> Default;
        V -> V
    end.
now() -> erlang:system_time(second).
