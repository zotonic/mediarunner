%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Verify isolated, durable consumer totals across cleanup, rollback and retries.
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

-module(mediarunner_statistics_tests).

-export([run/1]).

-include_lib("eunit/include/eunit.hrl").

%% @doc Use synthetic owners in the disposable integration database only.
run(Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    sys:suspend(Queue),
    try
        Now = erlang:system_time(second),
        Old = Now - 700000,
        job(-1, <<"completed">>, <<"delivered">>, false, Old, 10, Context),
        job(-1, <<"completed">>, <<"delivered">>, true, Old, 99, Context),
        job(-1, <<"failed">>, <<"failed">>, false, Old, 5, Context),
        job(-1, <<"queued">>, <<"waiting">>, false, Now, undefined, Context),
        job(-1, <<"running">>, <<"pending">>, false, Now, undefined, Context),
        job(-2, <<"completed">>, <<"delivered">>, false, Old, 1000, Context),
        cache(true, 200, Context),
        cache(false, 900, Context),
        Stats = mediarunner_statistics:snapshot(Context),
        Mine = maps:get(-1, Stats),
        ?assertMatch(#{<<"submitted">> := 5, <<"completed">> := 2, <<"failed">> := 1,
            <<"cache_hits">> := 1, <<"processing_seconds">> := 15,
            <<"callback_failures">> := 1, <<"queued">> := 1, <<"running">> := 1,
            <<"callbacks_pending">> := 1, <<"cached_files">> := 1, <<"cached_bytes">> := 200}, Mine),
        ?assertMatch(#{<<"submitted">> := 1, <<"processing_seconds">> := 1000}, maps:get(-2, Stats)),
        %% Rollback restores both job rows and totals, with no loss or double count.
        ?assertEqual(rolled_back, z_db:transaction(fun(Ctx) ->
            ok = mediarunner_statistics:archive(Now - 604800, Ctx),
            {rollback, rolled_back}
        end, Context)),
        ?assertEqual(Mine, maps:get(-1, mediarunner_statistics:snapshot(Context))),
        ?assertEqual(5, z_db:q1("select count(*) from mediarunner_job where owner_id=-1", Context)),
        ok = mediarunner_store:cleanup(Context),
        ?assertEqual(2, z_db:q1("select count(*) from mediarunner_job where owner_id=-1", Context)),
        ?assertEqual(Mine, maps:get(-1, mediarunner_statistics:snapshot(Context))),
        ok = mediarunner_store:cleanup(Context),
        ?assertEqual(Mine, maps:get(-1, mediarunner_statistics:snapshot(Context)))
    after
        lists:foreach(fun(Table) ->
            z_db:q("delete from " ++ Table ++ " where owner_id in (-1,-2)", Context)
        end, ["mediarunner_job", "mediarunner_cache", "mediarunner_consumer_totals"]),
        sys:resume(Queue)
    end.

job(Owner, Status, Delivery, Hit, Created, Duration, Context) ->
    Finished = case Duration of undefined -> undefined; _ -> Created + Duration end,
    {ok, _} = z_db:insert(mediarunner_job, #{
        <<"id">> => z_ids:id(32), <<"owner_id">> => Owner, <<"profile">> => <<"file">>,
        <<"request_hash">> => <<"statistics-fixture">>, <<"created">> => Created,
        <<"started">> => Created, <<"finished">> => Finished, <<"expires">> => Created + 3600,
        <<"status">> => Status, <<"delivery">> => Delivery, <<"cache_hit">> => Hit
    }, Context),
    ok.

cache(Complete, Size, Context) ->
    {ok, _} = z_db:insert(mediarunner_cache, #{
        <<"owner_id">> => -1, <<"kind">> => <<"file">>, <<"hash">> => z_ids:id(32),
        <<"data">> => <<>>, <<"size">> => Size, <<"used">> => erlang:system_time(second),
        <<"complete">> => Complete
    }, Context),
    ok.
