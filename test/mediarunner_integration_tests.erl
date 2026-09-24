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
    OldAuthorities = tls_certificate_check:trusted_authorities(),
    ok = tls_certificate_check:override_trusted_authorities({file, tls_path("ca.crt")}),
    Settings = [
        {media_runner_hostname, <<"localhost:18443">>},
        {media_runner_oauth2_key, Token},
        {media_runner_wait_timeout, 10},
        {media_runner_local_fallback, false}
    ],
    Old = [{K, application:get_env(zotonic, K)} || {K, _} <- Settings],
    OldCallbacks = application:get_env(mediarunner, mediarunner_callback_urls),
    lists:foreach(fun({K, V}) -> application:set_env(zotonic, K, V) end, Settings),
    application:set_env(mediarunner, mediarunner_callback_urls, [Callback]),
    try
        development_tls(Url, Token),
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"capabilities">>), <<"invalid">>, #{})),
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"capabilities">>), ReadOnly, #{})),
        {ok, #{<<"status">> := <<"ok">>, <<"result">> := #{imagemagick := _}}} =
            z_mqtt:call(<<"model/mediarunner_job/get/capabilities">>, #{}, Context),
        z_media_imagemagick:clear_cache(),
        LocalImageMagick = z_media_imagemagick:local(),
        RemoteImageMagick = z_media_imagemagick:selected(),
        ?assertEqual(true, maps:get(available, RemoteImageMagick)),
        ?assertEqual(maps:get(version, LocalImageMagick), maps:get(version, RemoteImageMagick)),
        ?assertEqual(maps:get(legacy, LocalImageMagick), z_media_preview:is_legacy_imagemagick()),
        ?assertEqual(
            Callback, z_dispatcher:url_for(media_runner_callback, [{absolute_url, true}], Context)
        ),
        ?assertEqual(
            {error, media_runner_configuration}, z_exec:run(file, <<"printf no-site">>, #{})
        ),
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), <<"invalid-token">>, #{})),
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), ReadOnly, #{})),
        ?assertEqual(ok, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), Token, #{})),
        ?assertEqual(
            {error, eacces},
            m_mediarunner:m_get([<<"status">>], undefined, z_context:new(mediarunner))
        ),
        mediarunner_queue_tests:run(Context),
        ?assertEqual({ok, <<"roundtrip">>}, z_exec:run(file, <<"printf roundtrip">>, #{}, Context)),
        status_lookup(Context),
        mediarunner_consumer_tests:run(z_media_runner_protocol:control_url(Url, <<"submit">>), Context),
        mediarunner_statistics_tests:run(Context),
        upload_checks(Url, Token, ReadOnly, Context),
        lists:foreach(fun(Mode) -> concurrent_upload(Mode, Context) end, [success, corrupt, killed]),
        expired_upload_claim(Context),
        image_roundtrip(Context),
        output_as_input(Context),
        result_during_upload(Context),
        mediarunner_http_tests:run(),
        large_result(Context),
        restart_recovery(Url, Token, Callback, Context),
        cache_isolation(Context),
        cache_checks(Context),
        mediarunner_cleanup_tests:run(Context),
        sandbox_dashboard(Context),
        fallback(Context),
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
        tls_certificate_check:override_trusted_authorities(OldAuthorities),
        z_notifier:detach(ssl_options, self(), Context),
        m_oauth2:delete_app(App, Context),
        lists:foreach(fun({K, V}) -> restore(zotonic, K, V) end, Old),
        restore(mediarunner, mediarunner_callback_urls, OldCallbacks)
    end.

%% The CI certificate is signed by a private CA, outside the default trust store.
development_tls(Url, Token) ->
    OldEnvironment = application:get_env(zotonic, environment),
    OldCa = tls_certificate_check:trusted_authorities(),
    try
        tls_certificate_check:override_trusted_authorities(certifi:cacerts()),
        application:set_env(zotonic, environment, production),
        ?assertMatch({error, _}, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), Token, #{})),
        application:set_env(zotonic, environment, development),
        ?assertEqual(ok, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), Token, #{}))
    after
        restore(zotonic, environment, OldEnvironment),
        tls_certificate_check:override_trusted_authorities(OldCa)
    end.

%% Status recovery is owner-scoped, including completed results and expiry.
status_lookup(Context) ->
    Id = z_ids:id(32),
    Result = #{<<"status">> => <<"ok">>, <<"stdout">> => <<>>, <<"files">> => []},
    Message = #{payload => #{<<"id">> => Id}},
    Now = erlang:system_time(second),
    %% Keep the result recoverable, with its callback retry deferred beyond this test.
    1 = z_db:q("
        insert into mediarunner_job
            (id,owner_id,profile,request_hash,created,expires,status,delivery,result,next_attempt)
        values ($1,$2,'file',$3,$4,$5,'completed','pending',$6,$7)",
        [Id, z_acl:user(Context), <<>>, Now, Now + 60, z_json:encode(Result), Now + 3600], Context),
    try
        ?assertEqual({ok, #{outcome => <<"completed">>, result => Result}},
            m_mediarunner_job:m_post([<<"status">>], Message, Context)),
        1 = z_db:q("update mediarunner_job set owner_id=-1 where id=$1", [Id], Context),
        ?assertEqual({error, enoent}, m_mediarunner_job:m_post([<<"status">>], Message, Context)),
        1 = z_db:q("update mediarunner_job set owner_id=$2,expires=0 where id=$1", [Id, z_acl:user(Context)], Context),
        ?assertEqual({error, enoent}, m_mediarunner_job:m_post([<<"status">>], Message, Context))
    after
        z_db:q("delete from mediarunner_job where id=$1", [Id], Context)
    end.

sandbox_dashboard(Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    ok = sys:suspend(Queue),
    ok = meck:new(z_exec, [passthrough]),
    try
        ?assertEqual({error, eacces}, m_mediarunner:m_get([<<"sandbox">>], undefined, z_context:new(mediarunner))),
        lists:foreach(fun({Probe, Expected, Text}) ->
            ok = meck:expect(z_exec, sandbox_status, fun() -> Probe end),
            ok = mediarunner_sandbox:refresh(Context),
            {ok, {#{state := Expected, message := Message}, []}} = m_mediarunner:m_get([<<"sandbox">>], undefined, Context),
            ?assertNotEqual(nomatch, binary:match(Message, Text)),
            {Rendered, _} = z_template:render_block_to_iolist(content, "mediarunner_dashboard.tpl", [], Context),
            Html = iolist_to_binary(Rendered),
            ?assertNotEqual(nomatch, binary:match(Html, <<"id=\"mr-sandbox\"">>)),
            ?assertNotEqual(nomatch, binary:match(Html, Text)),
            {match, [AlarmAttributes]} = re:run(Html, <<"<section id=\"mr-isolation-alarm\"([^>]*)>">>, [{capture, [1], binary}]),
            ?assertEqual(Expected =:= available, binary:match(AlarmAttributes, <<" hidden">>) =/= nomatch),
            ?assertNotEqual(nomatch, binary:match(AlarmAttributes, <<"role=\"alert\"">>)),
            {AlarmPos, _} = binary:match(Html, <<"id=\"mr-isolation-alarm\"">>),
            {HeadingPos, _} = binary:match(Html, <<"class=\"mr-heading\"">>),
            ?assert(AlarmPos < HeadingPos),
            AnonymousHtml = iolist_to_binary(z_template:render_block(content,
                "mediarunner_dashboard.tpl", [], z_context:new(mediarunner))),
            ?assertEqual(nomatch, binary:match(AnonymousHtml, <<"mr-isolation-alarm">>)),
            ?assertEqual(nomatch, binary:match(AnonymousHtml, <<"id=\"mr-sandbox\"">>))
        end, [
            {{ok, <<>>}, available, <<"run with sandbox isolation">>},
            {{error, {sandbox_unsupported, {unix, freebsd}}}, unsupported, <<"run without sandbox isolation">>},
            {{error, sandbox_helper_missing}, error, <<"processing is blocked">>}
        ])
    after
        meck:unload(z_exec),
        mediarunner_sandbox:refresh(Context),
        sys:resume(Queue)
    end.

large_result(Context) ->
    Frames = case os:getenv("MEDIARUNNER_TEST_RESULT_FRAMES") of
        false -> 48;
        N -> list_to_integer(N)
    end,
    Size = Frames * 1024 * 1024 * 3 div 2,
    Output = z_convert:to_list(z_tempfile:new()) ++ ".raw",
    OldWait = application:get_env(zotonic, media_runner_wait_timeout),
    application:set_env(zotonic, media_runner_wait_timeout, 180),
    HttpOptions = z_media_runner_protocol:http_options(30000),
    Jobs = ets:new(result_download_jobs, [public, set]),
    ok = meck:new(z_media_runner_protocol, [passthrough]),
    %% Observe both default-timeout requests and deadline-bounded client requests.
    ok = meck:expect(z_media_runner_protocol, request, fun(U, T, Payload) ->
        z_media_runner_protocol:request(U, T, Payload, 30000)
    end),
    ok = meck:expect(z_media_runner_protocol, request, fun(U, T, Payload, Timeout) ->
        case Payload of
            #{<<"id">> := JobId, <<"profile">> := <<"ffmpeg">>} -> ets:insert(Jobs, {current, JobId});
            _ -> ok
        end,
        Reply = meck:passthrough([U, T, Payload, Timeout]),
        case binary:match(U, <<"/post/received">>) of
            nomatch -> ok;
            _ -> ?assertEqual({ok, #{<<"outcome">> => <<"received">>}}, Reply)
        end,
        Reply
    end),
    ok = meck:expect(z_media_runner_protocol, unpack, fun(Result, Options) ->
        ?assert(byte_size(z_json:encode(Result)) < 2048),
        [#{<<"size">> := Size, <<"sha256">> := Hash, <<"url">> := Url} = F] = maps:get(<<"files">>, Result),
        ?assertNot(maps:is_key(<<"data">>, F)),
        ?assert(z_db:q1("select count(*) from mediarunner_job_file where hash=$1 and job_id=$2",
            [Hash, ets:lookup_element(Jobs, current, 2)], Context) > 0),
        {ok, {{_, 403, _}, _, _}} = httpc:request(get,
            {binary_to_list(Url), [{"authorization", "Bearer invalid"}]},
            HttpOptions, [], zotonic),
        ?assertEqual({error, missing}, mediarunner_cache:read(F, -1, Context)),
        meck:passthrough([Result, Options])
    end),
    try
        Command = ["ffmpeg -y -nostdin -v error -f lavfi -i color=c=black:s=1024x1024:r=25 -frames:v ",
            integer_to_list(Frames), " -threads 1 -pix_fmt yuv420p -f rawvideo ", z_filelib:os_filename(Output)],
        ?assertEqual({ok, <<>>}, z_exec:run(ffmpeg, Command, #{write => [Output], timeout => 180000}, Context)),
        {ok, Size, Hash} = z_media_runner_protocol:hash_file(Output),
        ?assertEqual(0, z_db:q1("select count(*) from mediarunner_job_file where hash=$1 and job_id=$2",
            [Hash, ets:lookup_element(Jobs, current, 2)], Context)),
        ?assertEqual(0, z_db:q1("select octet_length(data) from mediarunner_cache where kind='file' and owner_id=1 and hash=$1", [Hash], Context)),
        Hits = z_db:q1("select count(*) from mediarunner_job where profile='ffmpeg' and cache_hit", Context),
        ok = file:delete(Output),
        ?assertEqual({ok, <<>>}, z_exec:run(ffmpeg, Command, #{write => [Output], timeout => 180000}, Context)),
        ?assertEqual(Hits + 1, z_db:q1("select count(*) from mediarunner_job where profile='ffmpeg' and cache_hit", Context)),
        ?assertEqual({ok, Size, Hash}, z_media_runner_protocol:hash_file(Output)),
        {ok, Job} = z_media_runner_protocol:pack(ffmpeg, Command, #{write => [Output], timeout => 180000}),
        {ok, Cached} = mediarunner_cache:result(Job, 1, Context),
        [CachedFile] = maps:get(<<"files">>, Cached),
        {ok, {file, CachedPath}} = mediarunner_cache:read(CachedFile, 1, Context),
        ok = file:delete(CachedPath),
        ?assertEqual({error, missing}, mediarunner_cache:result(Job, 1, Context)),
        io:format("Streamed and verified ~B result bytes~n", [Size])
    after
        meck:unload(z_media_runner_protocol),
        ets:delete(Jobs),
        restore(zotonic, media_runner_wait_timeout, OldWait),
        file:delete(Output)
    end.

image_roundtrip(Context) ->
    Input = unicode:characters_to_binary(z_convert:to_list(z_tempfile:new()) ++ " quoted ' " ++ [16#4e2d, 16#e9] ++ " input.ppm"),
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
                    z_filelib:os_filename(unicode:characters_to_list(Input)),
                    " ",
                    z_filelib:os_filename(Output)
                ],
                #{read => [Input], write => [Output]},
                Context
            )
        ),
        {ok, <<137, "PNG", _/binary>>} = file:read_file(Output),
        {ok, Meta} = z_media_identify:identify_file(unicode:characters_to_binary(Input), z_context:new(mediarunner)),
        ?assertEqual(1, maps:get(<<"width">>, Meta)),
        ok = file:delete(Output),
        ?assertEqual(ok, z_media_preview:convert(Input, Output, [{width, 1}], Context)),
        {ok, <<137, "PNG", _/binary>>} = file:read_file(Output)
    after
        file:delete(Input),
        file:delete(Output)
    end.

%% A fresh output must satisfy a later input lookup without any file upload.
output_as_input(Context) ->
    Output = z_convert:to_list(z_tempfile:new()) ++ ".output",
    Input = Output ++ ".input",
    Value = z_ids:id(32),
    try
        Command = ["printf '%s\\n' ", binary_to_list(Value), " > ", z_filelib:os_filename(Output)],
        ?assertEqual({ok, <<>>}, z_exec:run(file, Command, #{write => [Output]}, Context)),
        {ok, Size, Hash} = z_media_runner_protocol:hash_file(Output),
        File = #{<<"sha256">> => Hash, <<"size">> => Size},
        {ok, {file, CachedPath}} = mediarunner_cache:read(File, 1, Context),
        ?assertEqual({error, missing}, mediarunner_cache:read(File, -1, Context)),
        %% Cache identity depends on content, not the local output filename.
        ok = file:rename(Output, Input),
        {ok, [Runner]} = z_media_runner_pool:runners(),
        ColdRunner = #{url => <<"https://cold.example/media-runner">>, token => <<"cold">>},
        {ok, Followup} = z_media_runner_protocol:pack(file, read_line(Input), #{read => [Input]}),
        ?assertEqual([Runner, ColdRunner],
            gen_server:call(z_media_runner, {rank, [ColdRunner, Runner], Followup})),
        ok = meck:new(z_media_runner_protocol, [passthrough]),
        try
            ?assertEqual({ok, Value}, z_exec:run(file, read_line(Input), #{read => [Input]}, Context)),
            ?assertEqual(0, meck:num_calls(z_media_runner_protocol, upload, '_')),
            ?assertEqual({ok, {file, CachedPath}}, mediarunner_cache:read(File, 1, Context)),
            ?assertEqual(1, z_db:q1("
                select count(*) from mediarunner_cache
                where owner_id = 1 and kind = 'file' and hash = $1", [Hash], Context))
        after
            meck:unload(z_media_runner_protocol)
        end,
        io:format("Command output reused as follow-up input without uploading.~n")
    after
        file:delete(Output),
        file:delete(Input)
    end.

restart_recovery(Url, Token, Callback, Context) ->
    Id = z_ids:id(32),
    Job = #{
        <<"version">> => 3,
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
    ?assertEqual(ok, z_media_runner_protocol:post(z_media_runner_protocol:control_url(Url, <<"submit">>), Token, Job)),
    ?assertEqual(
        {ok, #{<<"outcome">> => <<"conflict">>}},
        z_media_runner_protocol:request(z_media_runner_protocol:control_url(Url, <<"submit">>), Token, Job#{<<"command">> => <<"printf changed">>})
    ),
    ?assertEqual(1, z_db:q1("select count(*) from mediarunner_job where id=$1", [Id], Context)).

%% The same OAuth owner deliberately knows both cache paths. This checks the OS
%% sandbox, independently of owner isolation or the secrecy of cache filenames.
cache_isolation(Context) ->
    Input = z_convert:to_list(z_tempfile:new()) ++ "-allowed.txt",
    Other = z_convert:to_list(z_tempfile:new()) ++ "-unrelated.txt",
    Allowed = <<"allowed-", (z_ids:id(32))/binary>>,
    Secret = <<"secret-", (z_ids:id(32))/binary>>,
    ok = file:write_file(Input, <<Allowed/binary, "\n">>),
    ok = file:write_file(Other, <<Secret/binary, "\n">>),
    try
        lists:foreach(fun({Path, Expected}) ->
            ?assertEqual({ok, Expected}, z_exec:run(file, read_line(Path), #{read => [Path]}, Context))
        end, [{Input, Allowed}, {Other, Secret}]),
        {ok, _, InputHash} = z_media_runner_protocol:hash_file(Input),
        {ok, _, OtherHash} = z_media_runner_protocol:hash_file(Other),
        {ok, {file, CachedInput}} = mediarunner_cache:read(#{<<"sha256">> => InputHash}, 1, Context),
        {ok, {file, CachedOther}} = mediarunner_cache:read(#{<<"sha256">> => OtherHash}, 1, Context),
        CacheDir = filename:dirname(CachedInput),
        ?assertEqual(CacheDir, filename:dirname(CachedOther)),
        ?assertEqual({ok, <<Allowed/binary, "\n">>}, file:read_file(CachedInput)),
        ?assertEqual({ok, <<Secret/binary, "\n">>}, file:read_file(CachedOther)),
        Options = #{read => [Input]},
        lists:foreach(fun(Profile) ->
            %% The declared input remains usable, but even its cached original is denied.
            ?assertEqual({Profile, {ok, Allowed}}, {Profile, z_exec:run(Profile, read_line(Input), Options, Context)}),
            lists:foreach(fun(Path) ->
                Read = ["if IFS= read -r value < ", z_filelib:os_filename(Path),
                    "; then printf leaked; else printf denied; fi"],
                ?assertEqual({ok, <<"denied">>}, z_exec:run(Profile, Read, Options, Context))
            end, [CachedInput, CachedOther]),
            %% A shell glob enumerates directory entries without needing /bin/ls.
            Glob = [z_filelib:os_filename(CacheDir), "/*"],
            ?assertEqual({Profile, {ok, <<(z_convert:to_binary(CacheDir))/binary, "/*">>}},
                {Profile, z_exec:run(Profile, ["printf '%s' ", Glob], Options, Context)}),
            lists:foreach(fun(Path) ->
                Write = ["if printf corrupted > ", z_filelib:os_filename(Path),
                    "; then printf leaked; else printf denied; fi"],
                ?assertEqual({ok, <<"denied">>}, z_exec:run(Profile, Write, Options, Context))
            end, [CachedInput, CachedOther, filename:join(CacheDir, "forbidden-new-file")])
        end, [file, imagemagick, imagemagick_pdf, ffmpeg, ffmpeg_preview, ffprobe]),
        %% A declared read/write input is a copy: successful mutation must leave
        %% both the shared cached original and unrelated entries untouched.
        ?assertEqual({ok, <<>>}, z_exec:run(file,
            ["printf modified > ", z_filelib:os_filename(unicode:characters_to_list(Input))],
            #{read => [Input], write => [Input]}, Context)),
        ?assertEqual({ok, <<"modified">>}, file:read_file(Input)),
        ?assertEqual({ok, <<Allowed/binary, "\n">>}, file:read_file(CachedInput)),
        ?assertEqual({ok, <<Secret/binary, "\n">>}, file:read_file(CachedOther)),
        ?assertNot(filelib:is_file(filename:join(CacheDir, "forbidden-new-file"))),
        io:format("Cache content isolation verified for all media profiles.~n")
    after
        file:delete(Input),
        file:delete(Other)
    end.

read_line(Path) ->
    ["IFS= read -r value < ", z_filelib:os_filename(Path), "; printf '%s' \"$value\""].

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
            <<"size">> => byte_size(Data)
        }
    end,
    A = File(binary:copy(<<"A">>, 100)),
    B = File(binary:copy(<<"B">>, 100)),
    Id = z_ids:id(32),
    Job = #{
        <<"version">> => 3,
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
        %% Disposable test schema: isolate the tiny LRU budget from prior jobs.
        lists:foreach(fun
            ({undefined}) -> ok;
            ({P}) -> file:delete(P)
        end, z_db:q("delete from mediarunner_cache returning path", Context)),
        %% Free disk space must constrain even a very large configured cache.
        %% Pending uploads have no complete file to credit against disk usage.
        GiB = 1073741824,
        application:set_env(mediarunner, mediarunner_cache_max_bytes, 100 * GiB),
        ok = meck:new(mediarunner_capacity, [passthrough, no_link]),
        try
            ok = meck:expect(mediarunner_capacity, cache_disk, fun(_) ->
                {10 * GiB, GiB + 150}
            end),
            ?assertMatch(#{limit := 150}, mediarunner_cache:stats(Context)),
            HashA = maps:get(<<"sha256">>, A),
            HashB = maps:get(<<"sha256">>, B),
            {ok, Lease} = mediarunner_cache:upload({reserve, HashA, 100}, Owner, Context),
            ?assertEqual({error, full}, mediarunner_cache:upload({reserve, HashB, 100}, Owner, Context)),
            ok = mediarunner_cache:upload({abort, HashA, Lease}, Owner, Context),
            ok = meck:expect(mediarunner_capacity, cache_disk, fun(_) -> {0, 0} end),
            ?assertEqual({error, full}, mediarunner_cache:upload({reserve, HashB, 100}, Owner, Context))
        after
            meck:unload(mediarunner_capacity)
        end,
        application:set_env(mediarunner, mediarunner_cache_max_bytes, 150),
        ok = cache_upload(A, binary:copy(<<"A">>, 100), Owner, Context),
        {ok, Id} = mediarunner_store:enqueue(Job, Owner, Context),
        z_db:q("update mediarunner_cache set used=0 where owner_id=$1", [Owner], Context),
        ?assertEqual(
            {error, full}, mediarunner_cache:upload({reserve, maps:get(<<"sha256">>, B), 100}, Owner, Context)
        ),
        ?assertMatch({ok, _}, mediarunner_cache:read(A, Owner, Context)),
        mediarunner_cache:release(Id, Context),
        %% Reproduce a worker acquiring an eviction candidate after its selection.
        lists:foreach(fun(Action) ->
            z_db:q("update mediarunner_cache set used=0 where owner_id=$1", [Owner], Context),
            Race = make_ref(),
            TestPid = self(),
            ok = meck:new(z_db, [passthrough, no_link]),
            try
                ok = meck:expect(z_db, q, fun(Sql, Args, Ctx) ->
                    Rows = meck:passthrough([Sql, Args, Ctx]),
                    %% SQL layout is not part of the cache API. Match the
                    %% candidate query independently of spaces and line breaks.
                    CompactSql = re:replace(Sql, "\\s+", "", [global, {return, list}]),
                    case lists:prefix("selectowner_id,kind,hash,sizefrommediarunner_cache", CompactSql) of
                        true ->
                            case Action of
                                refresh -> {ok, _} = mediarunner_cache:read(A, Owner, Context);
                                pin -> ok = mediarunner_cache:pin(Id, Job, Context)
                            end,
                            TestPid ! {Race, Action};
                        false -> ok
                    end,
                    Rows
                end),
                Reply = mediarunner_cache:upload(
                    {reserve, maps:get(<<"sha256">>, B), 100}, Owner, Context),
                receive
                    {Race, Action} -> ok
                after 0 ->
                    error({cache_race_not_exercised, Action})
                end,
                ?assertEqual({error, full}, Reply),
                ?assertMatch({ok, _}, mediarunner_cache:read(A, Owner, Context))
            after
                meck:unload(z_db),
                mediarunner_cache:release(Id, Context)
            end
        end, [refresh, pin]),
        %% Recent uploads have a one-hour admission lease in addition to job pins.
        z_db:q("update mediarunner_cache set used=0 where owner_id=$1", [Owner], Context),
        ok = cache_upload(B, binary:copy(<<"B">>, 100), Owner, Context),
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
            {error, invalid_job},
            z_media_runner_protocol:validate(Job#{<<"files">> => [A#{<<"data">> => <<"tampered">>}]})
        )
    after
        z_db:q("delete from mediarunner_job where id=$1", [Id], Context),
        lists:foreach(fun
            ({undefined}) -> ok;
            ({P}) -> file:delete(P)
        end, z_db:q("delete from mediarunner_cache where owner_id=$1 returning path", [Owner], Context)),
        restore(mediarunner, mediarunner_cache_max_bytes, OldLimit),
        sys:resume(Queue)
    end.

cache_upload(F, Data, Owner, Context) ->
    H = maps:get(<<"sha256">>, F),
    {ok, Token} = mediarunner_cache:upload({reserve, H, byte_size(Data)}, Owner, Context),
    {ok, Path, _, _} = mediarunner_cache:upload({claim, H, Token}, Owner, Context),
    ok = file:write_file(Path, Data),
    mediarunner_cache:upload({complete, H, Token}, Owner, Context).

upload_checks(Url, Token, ReadOnly, Context) ->
    Path = z_convert:to_list(z_tempfile:new()) ++ "-large-source.bin",
    Size = case os:getenv("MEDIARUNNER_TEST_UPLOAD_BYTES") of
        false -> 70 * 1024 * 1024;
        N -> list_to_integer(N)
    end,
    {ok, Fd} = file:open(Path, [write, raw, binary]),
    ok = file:write(Fd, crypto:strong_rand_bytes(32)),
    {ok, _} = file:position(Fd, Size - 1),
    ok = file:write(Fd, <<42>>),
    ok = file:close(Fd),
    {ok, Size, Hash} = z_media_runner_protocol:hash_file(Path),
    FileUrl = <<Url/binary, "/files/", Hash/binary>>,
    ReserveUrl = z_media_runner_protocol:control_url(Url, <<"reserve">>),
    try
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(ReserveUrl, <<"invalid">>, #{<<"hash">> => Hash, <<"size">> => Size})),
        ?assertEqual({error, {http_status, 403}}, z_media_runner_protocol:post(ReserveUrl, ReadOnly, #{<<"hash">> => Hash, <<"size">> => Size})),
        {ok, Body} = z_media_runner_protocol:request(ReserveUrl, Token, #{<<"hash">> => Hash, <<"size">> => Size}),
        #{<<"upload_token">> := Lease} = Body,
        %% Another job cannot upload the same hash while this reservation is live.
        ?assertMatch({ok, #{<<"outcome">> := <<"busy">>}}, z_media_runner_protocol:request(ReserveUrl, Token, #{<<"hash">> => Hash, <<"size">> => Size})),
        ?assertEqual({error, missing}, mediarunner_cache:read(#{<<"sha256">> => Hash}, 1, Context)),
        ?assertEqual({ok, 204}, z_media_runner_protocol:upload(FileUrl, Token, Lease, Path, Size)),
        {ok, {file, Cached}} = mediarunner_cache:read(#{<<"sha256">> => Hash}, 1, Context),
        ?assertEqual({ok, Size, Hash}, z_media_runner_protocol:hash_file(Cached)),
        ?assertEqual(0, z_db:q1("select octet_length(data) from mediarunner_cache where owner_id=1 and hash=$1",
            [Hash], Context)),
        ?assertMatch({ok, #{<<"outcome">> := <<"present">>}}, z_media_runner_protocol:request(ReserveUrl, Token, #{<<"hash">> => Hash, <<"size">> => Size})),
        %% Both commands refer to the cached hash; source bytes are never in the job.
        Options = #{read => [Path]},
        ok = meck:new(z_media_runner_protocol, [passthrough, no_link]),
        try
            ?assertEqual({ok, <<"first">>}, z_exec:run(file, "printf first", Options, Context)),
            ?assertEqual({ok, <<"second">>}, z_exec:run(file, "printf second", Options, Context)),
            ?assertEqual(0, meck:num_calls(z_media_runner_protocol, upload, '_'))
        after
            meck:unload(z_media_runner_protocol)
        end,
        ?assertEqual({error, missing}, mediarunner_cache:read(#{<<"sha256">> => Hash}, 2, Context)),
        %% A body whose bytes do not match its reserved hash is never published.
        BadHash = binary:encode_hex(crypto:hash(sha256, <<"different bytes">>), lowercase),
        BadUrl = <<Url/binary, "/files/", BadHash/binary>>,
        {ok, BadBody} = z_media_runner_protocol:request(ReserveUrl, Token, #{<<"hash">> => BadHash, <<"size">> => 1}),
        #{<<"upload_token">> := BadLease} = BadBody,
        ?assertEqual({ok, 400}, z_media_runner_protocol:upload(BadUrl, Token, BadLease, Path, 1)),
        ?assertEqual({error, missing}, mediarunner_cache:read(#{<<"sha256">> => BadHash}, 1, Context)),
        ?assertEqual(0, z_db:q1("select count(*) from mediarunner_cache where hash=$1", [BadHash], Context)),
        upload_expiry(Context),
        io:format("Streaming upload verified for ~p bytes.~n", [Size])
    after
        file:delete(Path)
    end.

%% Use real client jobs and HTTP requests. Pause the first PUT after its claim,
%% then wait until the second client observes busy before allowing any progress.
concurrent_upload(Mode, Context) ->
    Parent = self(),
    Path = z_convert:to_list(z_tempfile:new()) ++ "-race.bin",
    BadPath = Path ++ ".bad",
    Data = crypto:strong_rand_bytes(4096),
    ok = file:write_file(Path, Data),
    ok = file:write_file(BadPath, binary:copy(<<0>>, byte_size(Data))),
    State = ets:new(upload_race, [public, set]),
    ets:insert(State, {attempts, 0}),
    Modules = [z_media_runner_protocol, mediarunner_queue],
    lists:foreach(fun(M) -> ok = meck:new(M, [passthrough, no_link]) end, Modules),
    try
        ok = meck:expect(z_media_runner_protocol, request, fun(U, T, Payload, Timeout) ->
            Reply = meck:passthrough([U, T, Payload, Timeout]),
            case Reply of
                {ok, #{<<"outcome">> := <<"busy">>}} -> Parent ! {race_waiting, self()};
                _ -> ok
            end,
            Reply
        end),
        ok = meck:expect(z_media_runner_protocol, upload, fun(U, T, Lease, File, Size) ->
            Attempt = ets:update_counter(State, attempts, 1),
            Source = case {Mode, Attempt} of
                {corrupt, 1} -> BadPath;
                _ -> File
            end,
            meck:passthrough([U, T, Lease, Source, Size])
        end),
        ok = meck:expect(mediarunner_queue, upload, fun(Request, Owner, Ctx) ->
            Reply = meck:passthrough([Request, Owner, Ctx]),
            case {Request, Reply} of
                {{claim, Hash, Lease}, {ok, Temp, _, _}} ->
                    ets:insert(State, {{server, self()}, true}),
                    Parent ! {race_claimed, self(), Hash, Lease, Temp},
                    receive continue -> ok after 10000 -> error(race_barrier_timeout) end;
                _ -> ok
            end,
            Reply
        end),
        First = start_race_job(Path, <<"printf first">>, Context, State),
        {Server, Hash, OldLease, Temp} = race_claim(),
        Second = start_race_job(Path, <<"printf second">>, Context, State),
        receive {race_waiting, Second} -> ok after 5000 -> error(second_job_did_not_wait) end,
        ?assertEqual([{attempts, 1}], ets:lookup(State, attempts)),
        receive {race_claimed, _, _, _, _} -> error(duplicate_uploader) after 0 -> ok end,
        case Mode of
            killed ->
                %% The claim is live, but an untrappable kill skips the controller's after clause.
                ok = file:write_file(Temp, <<"partial">>),
                exit(Server, kill);
            _ -> Server ! continue
        end,
        case Mode of
            success ->
                ?assertEqual({ok, <<"first">>}, race_result(First));
            _ ->
                ?assertMatch({error, _}, race_result(First)),
                {Successor, Hash, NewLease, NewTemp} = race_claim(),
                ?assertNotEqual(OldLease, NewLease),
                ?assertNotEqual(Temp, NewTemp),
                ?assertNot(filelib:is_file(Temp)),
                %% A delayed abort from the failed request cannot erase the new reservation.
                ok = mediarunner_queue:upload({abort, Hash, OldLease}, 1, Context),
                ?assertEqual(NewLease, z_db:q1(
                    "select upload_token from mediarunner_cache where owner_id=1 and hash=$1",
                    [Hash], Context)),
                Successor ! continue
        end,
        ?assertEqual({ok, <<"second">>}, race_result(Second)),
        Expected = case Mode of success -> 1; _ -> 2 end,
        ?assertEqual([{attempts, Expected}], ets:lookup(State, attempts)),
        #{uploads := Uploads} = sys:get_state(z_utils:name_for_site(mediarunner_queue, Context)),
        ?assertNot(lists:any(fun({_, H, _}) -> H =:= Hash end, maps:values(Uploads))),
        io:format("Concurrent upload ~p: ~p transfer attempt(s), waiting job completed.~n", [Mode, Expected])
    after
        lists:foreach(fun
            ({{server, Pid}, _}) -> exit(Pid, kill);
            ({{client, Pid}, _}) -> exit(Pid, kill);
            (_) -> ok
        end, ets:tab2list(State)),
        lists:foreach(fun meck:unload/1, Modules),
        ets:delete(State),
        file:delete(Path),
        file:delete(BadPath)
    end.

start_race_job(Path, Command, Context, State) ->
    Parent = self(),
    Pid = spawn(fun() ->
        Result = z_exec:run(file, Command, #{read => [Path]}, Context),
        Parent ! {race_finished, self(), Result}
    end),
    ets:insert(State, {{client, Pid}, true}),
    Pid.

race_claim() ->
    receive
        {race_claimed, Pid, Hash, Lease, Path} -> {Pid, Hash, Lease, Path}
    after 5000 -> error(no_upload_claim)
    end.

race_result(Pid) ->
    receive {race_finished, Pid, Result} -> Result
    after 10000 -> error(race_job_not_finished)
    end.

%% Simulate a client delayed between POST and PUT: the stale claim must cause
%% another reservation check, not an HTTP 409 failure of the media job.
expired_upload_claim(Context) ->
    Path = z_convert:to_list(z_tempfile:new()) ++ "-expired.bin",
    ok = file:write_file(Path, crypto:strong_rand_bytes(32)),
    Attempts = atomics:new(1, []),
    ok = meck:new(z_media_runner_protocol, [passthrough, no_link]),
    try
        ok = meck:expect(z_media_runner_protocol, upload, fun(U, Token, Lease, File, Size) ->
            case atomics:add_get(Attempts, 1, 1) of
                1 ->
                    1 = z_db:q("update mediarunner_cache set upload_expires=0 where upload_token=$1",
                        [Lease], Context);
                _ -> ok
            end,
            meck:passthrough([U, Token, Lease, File, Size])
        end),
        ?assertEqual({ok, <<"retried">>}, z_exec:run(file, "printf retried", #{read => [Path]}, Context)),
        ?assertEqual(2, atomics:get(Attempts, 1))
    after
        meck:unload(z_media_runner_protocol),
        file:delete(Path)
    end.

upload_expiry(Context) ->
    Owner = 999997,
    Hash = binary:encode_hex(crypto:hash(sha256, <<"partial upload">>), lowercase),
    {ok, Token} = mediarunner_queue:upload({reserve, Hash, 14}, Owner, Context),
    ?assertEqual({error, conflict}, mediarunner_queue:upload({claim, Hash, Token}, Owner + 1, Context)),
    {ok, Path, 14, _} = mediarunner_queue:upload({claim, Hash, Token}, Owner, Context),
    ?assertEqual({error, conflict}, mediarunner_queue:upload({claim, Hash, Token}, Owner, Context)),
    ok = file:write_file(Path, <<"partial">>),
    ?assertEqual({error, missing}, mediarunner_cache:read(#{<<"sha256">> => Hash}, Owner, Context)),
    z_db:q("update mediarunner_cache set upload_expires=0 where owner_id=$1", [Owner], Context),
    ok = mediarunner_cache:cleanup_uploads(false, Context),
    ?assertNot(filelib:is_file(Path)),
    ?assertEqual({error, conflict}, mediarunner_queue:upload({complete, Hash, Token}, Owner, Context)),
    {ok, NewToken} = mediarunner_queue:upload({reserve, Hash, 14}, Owner, Context),
    ?assertNotEqual(Token, NewToken),
    %% Restart cleanup removes unclaimed reservations as well as partial files.
    ok = mediarunner_cache:cleanup_uploads(true, Context),
    ?assertEqual(0, z_db:q1("select count(*) from mediarunner_cache where owner_id=$1", [Owner], Context)).

fallback(Context) ->
    application:set_env(zotonic, media_runner_hostname, <<"localhost:18999">>),
    ?assertMatch(
        {error, {media_runner_unavailable, _}},
        z_exec:run(file, <<"printf fallback">>, #{}, Context)
    ),
    application:set_env(zotonic, media_runner_local_fallback, true),
    ?assertEqual({ok, <<"fallback">>}, z_exec:run(file, <<"printf fallback">>, #{}, Context)),
    application:set_env(zotonic, media_runner_hostname, <<"localhost:18443">>),
    application:set_env(zotonic, media_runner_oauth2_key, <<"invalid-token">>),
    ?assertEqual(
        {error, {media_runner_http, 403}},
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

%% Completing a render must not compete with clients still uploading source bytes.
result_during_upload(Context) ->
    Old = application:get_env(mediarunner, mediarunner_uploads),
    application:set_env(mediarunner, mediarunner_uploads, 1),
    Hash = z_crypto:hex_sha2(z_ids:id(32)),
    {ok, Lease} = mediarunner_queue:upload({reserve, Hash, 100}, 1, Context),
    Output = z_tempfile:new(),
    Content = z_ids:id(32),
    try
        ?assertEqual({error, full}, mediarunner_queue:upload(
            {reserve, z_crypto:hex_sha2(z_ids:id(32)), 100}, 1, Context)),
        ?assertMatch({ok, _}, z_exec:run(file,
            ["printf ", Content, " > ", z_filelib:os_filename(Output)], #{write => [Output]}, Context)),
        ?assertEqual({ok, Content}, file:read_file(Output))
    after
        mediarunner_queue:upload({abort, Hash, Lease}, 1, Context),
        file:delete(Output),
        restore(mediarunner, mediarunner_uploads, Old)
    end.
