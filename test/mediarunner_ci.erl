%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Start an isolated media runner site and run the CI integration suite.
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

-module(mediarunner_ci).
-export([run/0]).

%% @doc Configure a disposable test instance, verify sandbox enforcement and run integration tests.
-spec run() -> ok.
run() ->
    try
        configure(),
        ok = zotonic:start(),
        ok = await_site(120),
        {ok, _} = z_exec:sandbox_status(),
        ok = mediarunner_integration_tests:run(),
        io:format("Media runner integration tests passed.~n"),
        init:stop(0)
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "Media runner CI failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
            init:stop(1)
    end.

%% Site discovery is asynchronous during Zotonic startup.
await_site(0) ->
    error(site_start_timeout);
await_site(Seconds) ->
    case z_sites_manager:get_site_status(mediarunner) of
        {ok, running} ->
            ok;
        Status ->
            case Status of
                {ok, stopped} -> z_sites_manager:start(mediarunner);
                {ok, new} -> z_sites_manager:start(mediarunner);
                _ -> ok
            end,
            timer:sleep(1000),
            await_site(Seconds - 1)
    end.

configure() ->
    Dir = os:getenv("MEDIARUNNER_CI_DIR"),
    true = is_list(Dir),
    ConfigDir = filename:join(Dir, "config"),
    DbHost =
        case os:getenv("ZOTONIC_DBHOST") of
            false -> "localhost";
            Host -> Host
        end,
    write_config(filename:join(ConfigDir, "zotonic.config"), [
        {zotonic, [
            {listen_ip, {127, 0, 0, 1}},
            {listen_ip6, none},
            {listen_port, 18080},
            {ssl_listen_port, 18443},
            {smtp_listen_port, 18252},
            {mqtt_listen_port, 18883},
            {mqtt_listen_ssl_port, 18884},
            {filewatcher_enabled, false},
            {environment, test},
            %% Exercise macOS-style paths throughout uploads, sandbox grants,
            %% result downloads and cleanup on every platform.
            {data_dir, filename:join([Dir, "Application Support", "zotonic"])},
            {dbhost, DbHost},
            {dbport, 5432},
            {dbdatabase, "zotonic"},
            {dbuser, "zotonic"},
            {dbpassword, "zotonic"}
        ]}
    ]),
    write_config(filename:join(ConfigDir, "erlang.config"), [
        {mnesia, [{dir, filename:join(Dir, "mnesia")}]}
    ]),
    SiteFile = "apps_user/mediarunner/priv/zotonic_site.config",
    {ok, [SiteConfig]} = file:consult(SiteFile),
    TestConfig = [
        {enabled, false},
        {hostname, "localhost"},
        {dbschema, "mediarunner_test"},
        {environment, test},
        {admin_password, "mediarunner-ci-only"}
    ],
    Merged = lists:foldl(
        fun({Key, _} = Setting, Acc) ->
            lists:keystore(Key, 1, Acc, Setting)
        end,
        SiteConfig,
        TestConfig
    ),
    write_config(SiteFile, Merged).

write_config(Path, Term) ->
    ok = file:write_file(Path, io_lib:format("~p.~n", [Term])).
