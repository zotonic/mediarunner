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
            {rollback, ok}
        end, Context))
    after
        sys:resume(Queue)
    end.

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
