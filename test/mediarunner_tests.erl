%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Test runner authorization, request policies, capacity sizing and dashboard charts.
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

-module(mediarunner_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

request_boundary_test() ->
    Url = <<"https://client.example/media-runner/callback">>,
    Job = #{
        <<"version">> => 3,
        <<"profile">> => <<"file">>,
        <<"command">> => <<"printf ok">>,
        <<"files">> => [],
        <<"timeout">> => 1000,
        <<"id">> => <<"test_job_123456789">>,
        <<"callback_url">> => Url,
        <<"callback_token">> => base64:encode(crypto:strong_rand_bytes(32)),
        <<"expires">> => erlang:system_time(second) + 60
    },
    ?assertEqual(ok, m_mediarunner_job:validate(Job, [Url])),
    ?assertEqual(ok, m_mediarunner_job:validate(Job, any)),
    ?assertEqual(ok, m_mediarunner_job:validate(Job, undefined)),
    lists:foreach(
        fun(J) ->
            ?assertEqual({error, invalid_job}, m_mediarunner_job:validate(J, [Url]))
        end,
        [
            Job#{<<"callback_url">> => <<"https://127.0.0.1/private">>},
            Job#{<<"expires">> => 1},
            Job#{<<"id">> => <<"../path?with=bad&params">>},
            Job#{<<"callback_token">> => <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\nHeader: injected">>}
        ]
    ),
    ?assertEqual({error, invalid_job}, m_mediarunner_job:validate(Job, [])).

capacity_test() ->
    GiB = 1073741824,
    ?assertEqual(3, mediarunner_capacity:workers(8, 16 * GiB, 4 * GiB)),
    ?assertEqual(3, mediarunner_capacity:workers(4, 128 * GiB, 4 * GiB)),
    ?assertEqual(1, mediarunner_capacity:workers(1, 128 * GiB, 4 * GiB)),
    ?assertEqual(1, mediarunner_capacity:workers(8, 0, 4 * GiB)),
    ?assertEqual(32, mediarunner_capacity:workers(128, 1024 * GiB, 4 * GiB)).

cache_capacity_test() ->
    GiB = 1073741824,
    %% A configured ceiling cannot exceed the disk or consume its reserve.
    ?assertEqual(9 * GiB, mediarunner_capacity:cache_limit(100 * GiB, 10 * GiB, 10 * GiB, 0)),
    ?assertEqual(2 * GiB, mediarunner_capacity:cache_limit(2 * GiB, 10 * GiB, 10 * GiB, 0)),
    %% Existing complete files are already subtracted from available space.
    ?assertEqual(5 * GiB, mediarunner_capacity:cache_limit(100 * GiB, 10 * GiB, 2 * GiB, 4 * GiB)),
    ?assertEqual(0, mediarunner_capacity:cache_limit(100 * GiB, 10 * GiB, GiB div 2, 0)),
    ?assertEqual(0, mediarunner_capacity:cache_limit(100 * GiB, GiB div 2, GiB div 2, 0)),
    ?assertEqual(0, mediarunner_capacity:cache_limit(100 * GiB, 0, 0, 0)).

callback_policy_test() ->
    Url = <<"https://client.example/media-runner/callback">>,
    ?assert(mediarunner_callback:is_allowed(Url, any)),
    ?assert(mediarunner_callback:is_allowed(Url, undefined)),
    ?assert(mediarunner_callback:is_allowed(Url, [binary_to_list(Url)])),
    ?assertNot(mediarunner_callback:is_allowed(Url, [])),
    ?assertNot(mediarunner_callback:is_allowed(Url, [<<"https://other.example/callback">>])),
    lists:foreach(
        fun(U) -> ?assertNot(mediarunner_callback:is_allowed(U, any)) end,
        [
            <<"http://client.example/callback">>,
            <<Url/binary, "?id=bad">>,
            <<Url/binary, "#fragment">>,
            <<"https://user:password@client.example/callback">>,
            undefined
        ]
    ).

chart_snapshot_test() ->
    Snapshot = #{
        updated => 90000,
        hourly => [
            #{<<"hour">> => 90000, <<"completed">> => 7, <<"failed">> => 2}
        ]
    },
    Charts = mediarunner_charts:render(Snapshot, #context{site = zotonic_site_testsandbox}),
    Completed = maps:get(completed, Charts),
    Failed = maps:get(failed, Charts),
    ?assertNotEqual(nomatch, binary:match(Completed, <<"01:00: 7">>)),
    ?assertNotEqual(nomatch, binary:match(Failed, <<"01:00: 2">>)),
    ?assertNotEqual(nomatch, binary:match(Completed, <<"02:00: 0">>)),
    ?assertNotEqual(nomatch, binary:match(Completed, <<"<polyline ">>)),
    ?assertNotEqual(nomatch, binary:match(Completed, <<"aria-describedby='mr-chart-table'">>)),
    ?assertEqual(nomatch, binary:match(Completed, <<"<table ">>)).

authorization_context_test() ->
    Anonymous = #context{site = zotonic_site_testsandbox},
    ?assertEqual({error, eacces}, m_mediarunner_job:authorize(Anonymous)),
    ReadOnly = Anonymous#context{user_id = 123, acl_is_read_only = true},
    ?assertEqual({error, eacces}, m_mediarunner_job:authorize(ReadOnly)),
    ?assertEqual(ok, m_mediarunner_job:authorize(z_acl:sudo(Anonymous))),
    lists:foreach(fun(Context) ->
        ?assertEqual({error, eacces}, m_mediarunner_job:m_get([<<"capabilities">>], undefined, Context)),
        lists:foreach(fun(Operation) ->
            ?assertEqual({error, eacces}, m_mediarunner_job:m_post([Operation], #{payload => #{}}, Context))
        end, [<<"submit">>, <<"reserve">>, <<"received">>, <<"status">>])
    end, [Anonymous, ReadOnly]).
