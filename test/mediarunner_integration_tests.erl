%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Test OAuth, processing, callbacks, cache and recovery on a disposable runner site.
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

-module(mediarunner_integration_tests).

-moduledoc "\n"
"Explicit integration test for a disposable mediarunner site on localhost:18443. Never run\n"
"against a production site/database.\n".
-export([run/0, ssl_options/2]).
-include_lib("eunit/include/eunit.hrl").

run() ->
    Context = z_acl:sudo(z_context:new(mediarunner)),
    ?assertEqual("mediarunner_test", m_site:get(dbschema, Context)),
    Url = <<"https://localhost:18443/media-runner/jobs">>,
    Callback = <<"https://localhost:18443/media-runner/callback">>,
    {ok, App} = m_oauth2:insert_app(
        #{<<"description">> => <<"Disposable media runner integration test">>}, Context
    ),
    {ok, TokenId} = m_oauth2:insert_token(
        App,
        1,
        undefined,
        #{<<"is_full_access">> => true, <<"is_read_only">> => false},
        Context
    ),
    {ok, Token} = m_oauth2:encode_bearer_token(TokenId, 3600, Context),
    {ok, ReadOnlyId} = m_oauth2:insert_token(
        App,
        1,
        undefined,
        #{<<"is_full_access">> => true, <<"is_read_only">> => true},
        Context
    ),
    {ok, ReadOnly} = m_oauth2:encode_bearer_token(ReadOnlyId, 3600, Context),
    ok = z_notifier:observe(ssl_options, {?MODULE, ssl_options}, self(), Context),
    Cert = tls_path("ca.crt"),
    Settings = [
        {media_runner_url, Url},
        {media_runner_oauth2_key, Token},
        {media_runner_imagemagick_legacy, os:find_executable("magick") =:= false},
        {media_runner_cacertfile, Cert},
        {media_runner_wait_timeout, 10000},
        {media_runner_local_fallback, false}
    ],
    Old = [{K, application:get_env(zotonic, K)} || {K, _} <- Settings],
    OldCallbacks = application:get_env(mediarunner, mediarunner_callback_urls),
    lists:foreach(fun({K, V}) -> application:set_env(zotonic, K, V) end, Settings),
    application:set_env(mediarunner, mediarunner_callback_urls, [Callback]),
    try
        ?assertEqual(
            Callback, z_dispatcher:url_for(media_runner_callback, [{absolute_url, true}], Context)
        ),
        ?assertEqual(
            {error, media_runner_configuration}, z_exec:run(file, <<"printf no-site">>, #{})
        ),
        ?assertEqual({ok, 401}, z_media_runner_protocol:post(Url, <<"invalid-token">>, #{})),
        ?assertEqual({ok, 403}, z_media_runner_protocol:post(Url, ReadOnly, #{})),
        ?assertEqual({ok, 400}, z_media_runner_protocol:post(Url, Token, #{})),
        ?assertEqual(
            {error, eacces},
            m_mediarunner:m_get([<<"status">>], undefined, z_context:new(mediarunner))
        ),
        ?assertEqual({ok, <<"roundtrip">>}, z_exec:run(file, <<"printf roundtrip">>, #{}, Context)),
        image_roundtrip(Context),
        restart_recovery(Url, Token, Callback, Context),
        cache_checks(Context),
        fallback(Url, Context),
        #{jobs := Jobs} = mediarunner_store:snapshot(<<>>, Context),
        ?assert(length(Jobs) >= 3),
        lists:foreach(
            fun(J) ->
                ?assertNot(maps:is_key(<<"callback_token">>, J)),
                ?assertNot(maps:is_key(<<"payload">>, J))
            end,
            Jobs
        ),
        ok
    after
        z_notifier:detach(ssl_options, self(), Context),
        m_oauth2:delete_app(App, Context),
        lists:foreach(fun({K, V}) -> restore(zotonic, K, V) end, Old),
        restore(mediarunner, mediarunner_callback_urls, OldCallbacks)
    end.

image_roundtrip(Context) ->
    Input = z_convert:to_list(z_tempfile:new()) ++ " quoted ' input.ppm",
    Output = z_convert:to_list(z_tempfile:new()) ++ ".png",
    ok = file:write_file(Input, <<"P3\n1 1\n255\n255 0 0\n">>),
    try
        ?assertMatch(
            {ok, _},
            z_exec:run(
                imagemagick,
                [
                    image_command(),
                    " ",
                    z_filelib:os_filename(Input),
                    " ",
                    z_filelib:os_filename(Output)
                ],
                #{read => [Input], write => [Output]},
                Context
            )
        ),
        {ok, <<137, "PNG", _/binary>>} = file:read_file(Output),
        {ok, Meta} = z_media_identify:identify_file(z_convert:to_binary(Input), z_context:new(mediarunner)),
        ?assertEqual(1, maps:get(<<"width">>, Meta)),
        ok = file:delete(Output),
        ?assertEqual(ok, z_media_preview:convert(Input, Output, [{width, 1}], Context)),
        {ok, <<137, "PNG", _/binary>>} = file:read_file(Output)
    after
        file:delete(Input),
        file:delete(Output)
    end.

restart_recovery(Url, Token, Callback, Context) ->
    Id = z_ids:id(32),
    Job = #{
        <<"version">> => 1,
        <<"id">> => Id,
        <<"profile">> => <<"file">>,
        <<"command">> => <<"printf recovered">>,
        <<"files">> => [],
        <<"timeout">> => 1000,
        <<"callback_url">> => Callback,
        <<"callback_token">> => base64:encode(crypto:strong_rand_bytes(32)),
        <<"expires">> => erlang:system_time(second) + 60
    },
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    ok = sys:suspend(Queue),
    {ok, Id} = mediarunner_store:enqueue(Job, 1, Context),
    1 = z_db:q("update mediarunner_job set status='running' where id=$1", [Id], Context),
    exit(Queue, kill),
    await(
        fun() ->
            z_db:q1("select status from mediarunner_job where id=$1", [Id], Context) =:=
                <<"completed">>
        end,
        100
    ),
    ?assertEqual({ok, 202}, z_media_runner_protocol:post(Url, Token, Job)),
    ?assertEqual(
        {ok, 409},
        z_media_runner_protocol:post(Url, Token, Job#{<<"command">> => <<"printf changed">>})
    ),
    ?assertEqual(1, z_db:q1("select count(*) from mediarunner_job where id=$1", [Id], Context)).

cache_checks(Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    ok = sys:suspend(Queue),
    OldLimit = application:get_env(mediarunner, mediarunner_cache_max_bytes),
    Owner = 999998,
    File = fun(Data) ->
        #{
            <<"id">> => 1,
            <<"write">> => false,
            <<"sha256">> => binary:encode_hex(crypto:hash(sha256, Data), lowercase),
            <<"data">> => base64:encode(Data)
        }
    end,
    A = File(binary:copy(<<"A">>, 100)),
    B = File(binary:copy(<<"B">>, 100)),
    Id = z_ids:id(32),
    Job = #{
        <<"version">> => 1,
        <<"profile">> => <<"file">>,
        <<"command">> => <<"printf cache-test">>,
        <<"files">> => [A],
        <<"timeout">> => 1000,
        <<"id">> => Id,
        <<"callback_url">> => <<"https://localhost:18443/media-runner/callback">>,
        <<"callback_token">> => base64:encode(crypto:strong_rand_bytes(32)),
        <<"expires">> => erlang:system_time(second) + 60
    },
    try
        application:set_env(mediarunner, mediarunner_cache_max_bytes, 150),
        {ok, Id} = mediarunner_store:enqueue(Job, Owner, Context),
        ?assertEqual(
            {error, full}, mediarunner_cache:prepare(Job#{<<"files">> => [B]}, Owner, Context)
        ),
        ?assertMatch({ok, _}, mediarunner_cache:read(A, Owner, Context)),
        mediarunner_cache:release(Id, Context),
        ok = mediarunner_cache:prepare(Job#{<<"files">> => [B]}, Owner, Context),
        ?assertEqual({error, missing}, mediarunner_cache:read(A, Owner, Context)),
        ?assertEqual({error, missing}, mediarunner_cache:read(B, Owner + 1, Context)),
        ?assertEqual(
            ok,
            mediarunner_cache:prepare(
                Job#{<<"files">> => [maps:remove(<<"data">>, B)]}, Owner, Context
            )
        ),
        ?assertMatch(
            {error, {missing, [_]}},
            mediarunner_cache:prepare(mediarunner_cache:strip(Job), Owner, Context)
        ),
        application:set_env(mediarunner, mediarunner_cache_max_bytes, 4096),
        Result = #{<<"status">> => <<"ok">>, <<"stdout">> => <<>>, <<"files">> => []},
        ok = mediarunner_cache:put_result(Job, Owner, Result, Context),
        ?assertEqual(
            {ok, Result},
            mediarunner_cache:result(
                Job#{<<"id">> => <<"different-job">>, <<"callback_token">> => <<"changed">>},
                Owner,
                Context
            )
        ),
        ?assertEqual(
            {error, missing},
            mediarunner_cache:result(
                Job#{<<"command">> => <<"different operation">>}, Owner, Context
            )
        ),
        ?assertEqual(
            {error, missing}, mediarunner_cache:result(Job#{<<"files">> => [B]}, Owner, Context)
        ),
        ?assertEqual({error, missing}, mediarunner_cache:result(Job, Owner + 1, Context)),
        ?assertEqual(
            {error, invalid_cache_file},
            mediarunner_cache:prepare(
                Job#{<<"files">> => [A#{<<"data">> => base64:encode(<<"tampered">>)}]},
                Owner,
                Context
            )
        )
    after
        z_db:q("delete from mediarunner_job where id=$1", [Id], Context),
        z_db:q("delete from mediarunner_cache where owner_id=$1", [Owner], Context),
        restore(mediarunner, mediarunner_cache_max_bytes, OldLimit),
        sys:resume(Queue)
    end.

fallback(Url, Context) ->
    application:set_env(zotonic, media_runner_url, <<"https://localhost:18999/jobs">>),
    ?assertMatch(
        {error, {media_runner_unavailable, _}},
        z_exec:run(file, <<"printf fallback">>, #{}, Context)
    ),
    application:set_env(zotonic, media_runner_local_fallback, true),
    ?assertEqual({ok, <<"fallback">>}, z_exec:run(file, <<"printf fallback">>, #{}, Context)),
    application:set_env(zotonic, media_runner_url, Url),
    application:set_env(zotonic, media_runner_oauth2_key, <<"invalid-token">>),
    ?assertEqual(
        {error, {media_runner_http, 401}},
        z_exec:run(file, <<"printf must-not-fallback">>, #{}, Context)
    ).
await(_, 0) ->
    error(await_timeout);
await(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            await(F, N - 1)
    end.
restore(App, K, undefined) -> application:unset_env(App, K);
restore(App, K, {ok, V}) -> application:set_env(App, K, V).

ssl_options(_, _) ->
    {ok, [{certfile, tls_path("server.crt")}, {keyfile, tls_path("server.key")}]}.

image_command() ->
    case os:find_executable("magick") of
        false -> "convert";
        _ -> "magick"
    end.

tls_path(Name) ->
    Dir =
        case os:getenv("MEDIARUNNER_TEST_TLS_DIR") of
            false -> "/tmp/zmr-tls";
            Value -> Value
        end,
    filename:join(Dir, Name).
