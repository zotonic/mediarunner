%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Verify thumbnail batch admission and bounded result storage during processing.
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

-module(mediarunner_queue_tests).

-export([run/1]).

-include_lib("eunit/include/eunit.hrl").

%% @doc Exercise a full small-job batch in the disposable integration database.
run(Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    sys:suspend(Queue),
    try
        %% This CI schema retains history between runs. Isolate the batch inside
        %% a transaction and roll it back, preserving all pre-existing job rows.
        ?assertEqual(ok, z_db:transaction(fun(Ctx) ->
            z_db:q("delete from mediarunner_job", Ctx),
            batch(Ctx),
            profile_selection(Ctx),
            {rollback, ok}
        end, Context))
    after
        sys:resume(Queue)
    end,
    lists:foreach(fun(Limit) -> scheduling(Limit, Context) end, [1, 2]).

batch(Context) ->
    ?assertEqual(0, z_db:q1("select count(*) from mediarunner_job", Context)),
    ?assertEqual(1000, maps:get(queue_limit, mediarunner_store:snapshot(<<>>, Context))),
    Job = #{
        <<"version">> => 3, <<"profile">> => <<"file">>,
        <<"command">> => <<"printf thumbnail">>, <<"files">> => [],
        <<"timeout">> => 1000, <<"callback_url">> => <<"https://client.example/callback">>,
        <<"callback_token">> => z_ids:id(44),
        <<"expires">> => erlang:system_time(second) + 3600
    },
    Jobs = [Job#{<<"id">> => z_ids:id(32)} || _ <- lists:seq(1, 1000)],
    lists:foreach(fun(J) ->
        ?assertEqual({ok, maps:get(<<"id">>, J)}, mediarunner_store:enqueue(J, -3, Context))
    end, Jobs),
    ?assertEqual({error, full}, mediarunner_store:enqueue(Job#{<<"id">> => z_ids:id(32)}, -3, Context)),
    %% An idempotent resubmission does not consume a second queue slot.
    [First | _] = Jobs,
    ?assertEqual({ok, maps:get(<<"id">>, First)}, mediarunner_store:enqueue(First, -3, Context)),
    Active = dispatch(Context, []),
    ?assert(length(Active) > 0),
    ?assert(length(Active) < 1000),
    check_budget(Context),
    [Started | _] = Active,
    Id = maps:get(<<"id">>, Started),
    ok = mediarunner_store:started(Id, Context),
    ?assertEqual(none, mediarunner_store:next(run, Context)),
    %% A small result replaces the large execution reservation and permits
    %% another waiting job to start, even before its callback is delivered.
    ok = mediarunner_store:result(Id,
        #{<<"status">> => <<"ok">>, <<"stdout">> => <<>>, <<"files">> => []}, Context),
    ?assertMatch({run, _}, mediarunner_store:next(run, Context)),
    check_budget(Context).

dispatch(Context, Acc) ->
    case mediarunner_store:next(run, Context) of
        none -> Acc;
        {run, Job} -> dispatch(Context, [Job | Acc])
    end.

check_budget(Context) ->
    [{Bytes, Active}] = z_db:q("select sum(octet_length(payload)+coalesce(octet_length(result),0)), "
        "count(*) filter (where status in ('starting','running')) from mediarunner_job "
        "where payload is not null", Context),
    ?assert(Bytes + Active * z_media_runner_protocol:callback_limit() =< 1073741824).

%% Even an older ffmpeg backlog cannot consume the last result envelope or hide
%% a later image job. This runs inside the rolled-back database transaction.
profile_selection(Context) ->
    z_db:q("delete from mediarunner_job", Context),
    Video = test_job(<<"ffmpeg">>),
    Image = test_job(<<"imagemagick">>),
    lists:foreach(fun(J) ->
        {ok, _} = mediarunner_store:enqueue(J, -4, Context)
    end, [Video, test_job(<<"ffmpeg">>), Image]),
    Old = application:get_env(mediarunner, mediarunner_storage_limit),
    application:set_env(mediarunner, mediarunner_storage_limit,
        2 * z_media_runner_protocol:callback_limit() + 65536),
    try
        ?assertMatch({ffmpeg, _}, mediarunner_store:next(ffmpeg, Context)),
        ?assertEqual(none, mediarunner_store:next(ffmpeg, Context)),
        {run, #{<<"id">> := ImageId}} = mediarunner_store:next(run, Context),
        ?assertEqual(maps:get(<<"id">>, Image), ImageId)
    after restore(mediarunner_storage_limit, Old) end.

%% Hold actual coordinator workers at the execution boundary. Both configured
%% ffmpeg limits must leave image jobs runnable with just one general worker.
scheduling(Limit, Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    await_idle(Queue, 100),
    #{capacity := OldCapacity} = sys:get_state(Queue),
    Capacity = OldCapacity#{workers => 1, ffmpeg_workers => Limit},
    ok = mediarunner_capacity:configure(Capacity, Context),
    _ = sys:replace_state(Queue, fun(S) -> S#{capacity => Capacity, ticks => 1} end),
    %% Keep this scheduling test independent of load on the CI host; retain real
    %% jobs counters, but suppress external CPU/memory modifier samples.
    lists:foreach(fun({Kind, N}) ->
        ok = jobs:modify_counter({counter, mediarunner_capacity:queue(Kind, Context), 1},
            [{limit, N}, {modifiers, []}])
    end, [{run, 1}, {ffmpeg, Limit}]),
    Parent = self(),
    ok = meck:new(z_media_runner_protocol, [passthrough, no_link]),
    ok = meck:expect(z_media_runner_protocol, execute, fun(Job, _Resolve, _Store, _Dir) ->
        Parent ! {executing, maps:get(<<"profile">>, Job), maps:get(<<"id">>, Job), self()},
        receive finish -> #{<<"status">> => <<"ok">>, <<"stdout">> => <<>>, <<"files">> => []}
        after 15000 -> error(test_execution_timeout) end
    end),
    ok = meck:expect(z_media_runner_protocol, post, fun(_, _, _) -> {ok, 204} end),
    try
        lists:foreach(fun(_) ->
            {ok, _} = mediarunner_queue:submit(test_job(<<"ffmpeg">>), -4, Context)
        end, lists:seq(1, Limit + 1)),
        Videos = [await_execution(<<"ffmpeg">>) || _ <- lists:seq(1, Limit)],
        ?assertEqual(1, z_db:q1("select count(*) from mediarunner_job "
            "where owner_id=-4 and status='queued' and profile='ffmpeg'", Context)),
        {ok, _} = mediarunner_queue:submit(test_job(<<"imagemagick">>), -4, Context),
        {_ImageId, ImagePid} = await_execution(<<"imagemagick">>),
        %% No extra render may start while the image worker is running either.
        receive {executing, <<"ffmpeg">>, _, _} -> error(ffmpeg_limit_exceeded)
        after 100 -> ok end,
        ImagePid ! finish,
        %% Lightweight ffmpeg previews and probes bypass the render backlog too.
        lists:foreach(fun(Profile) ->
            {ok, _} = mediarunner_queue:submit(test_job(Profile), -4, Context),
            {_, Pid} = await_execution(Profile),
            Pid ! finish
        end, [<<"ffmpeg_preview">>, <<"ffprobe">>]),
        %% A crashed video releases its slot and starts the waiting render.
        [{VideoId, VideoPid} | Rest] = Videos,
        exit(VideoPid, kill),
        {_, NextPid} = await_execution(<<"ffmpeg">>),
        ?assertEqual(<<"failed">>, z_db:q1(
            "select status from mediarunner_job where id=$1", [VideoId], Context)),
        lists:foreach(fun({_, Pid}) -> Pid ! finish end, Rest),
        NextPid ! finish,
        await_idle(Queue, 100),
        io:format("Independent general/ffmpeg scheduling verified with ~p video workers.~n", [Limit])
    after
        #{active := Active} = sys:get_state(Queue),
        lists:foreach(fun({_, _, Pid}) -> Pid ! finish end, maps:values(Active)),
        await_idle(Queue, 100),
        meck:unload(z_media_runner_protocol),
        z_db:q("delete from mediarunner_job where owner_id=-4", Context),
        ok = mediarunner_capacity:configure(OldCapacity, Context),
        _ = sys:replace_state(Queue, fun(S) -> S#{capacity => OldCapacity} end)
    end.

await_execution(Profile) ->
    receive {executing, Profile, Id, Pid} -> {Id, Pid}
    after 10000 -> error({worker_not_started, Profile}) end.

await_idle(_, 0) -> error(queue_not_idle);
await_idle(Queue, N) ->
    case sys:get_state(Queue) of
        #{active := Active} when map_size(Active) =:= 0 -> ok;
        _ -> timer:sleep(100), await_idle(Queue, N - 1)
    end.

test_job(Profile) ->
    Id = z_ids:id(32),
    #{<<"version">> => 3, <<"id">> => Id, <<"profile">> => Profile,
        <<"command">> => <<"printf ", Id/binary>>, <<"files">> => [],
        <<"timeout">> => 1000, <<"callback_url">> => <<"https://localhost:18443/media-runner/callback">>,
        <<"callback_token">> => z_ids:id(44), <<"expires">> => erlang:system_time(second) + 3600}.

restore(Key, undefined) -> application:unset_env(mediarunner, Key);
restore(Key, {ok, Value}) -> application:set_env(mediarunner, Key, Value).
