%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Test httpc transfers, JSON responses, cancellation and concurrency over real TLS.
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

-module(mediarunner_http_tests).
-export([run/0]).
-include_lib("eunit/include/eunit.hrl").

%% @doc Verify trusted small replies, disabled redirects and independent connections.
run() ->
    Old = application:get_env(zotonic, environment),
    application:set_env(zotonic, environment, development),
    try
        lists:foreach(fun(Code) ->
            with_server(response(Code, <<"Content-Length: 2\r\n">>, <<"ok">>), fun(Url) ->
                ?assertEqual({ok, Code, <<"ok">>}, request(Url, 2000))
            end),
            with_server(response(Code, <<"Content-Length: 70000\r\n">>,
                    binary:copy(<<"x">>, 70000)), fun(Url) ->
                ?assertEqual({error, response_too_large}, request(Url, 2000))
            end)
        end, [200, 201, 412, 500]),
        with_server(response(200, <<"Transfer-Encoding: chunked\r\n">>,
                <<"2\r\nok\r\n0\r\n\r\n">>), fun(Url) ->
            ?assertEqual({ok, 200, <<"ok">>}, request(Url, 2000))
        end),
        with_server(response(200, <<"Content-Length: 100\r\n">>, <<"x">>), fun(Url) ->
            ?assertEqual({error, timeout}, request(Url, 200))
        end),
        with_server(response(302, <<"Location: https://unreachable.invalid/\r\nContent-Length: 0\r\n">>, <<>>),
            fun(Url) ->
                ?assertEqual({error, {http_status, 302}},
                    z_media_runner_protocol:request(Url, <<"test">>, #{}, 2000))
            end),
        with_server(response(500, <<"Content-Length: 2\r\n">>, <<"no">>), fun(Url) ->
            ?assertEqual({error, {http_status, 500}},
                z_media_runner_http:download(Url, [], "/tmp/zmr-must-not-create", 1, 2000))
        end),
        Temp = z_tempfile:new(),
        try
            with_server(response(200, <<"Content-Length: 0\r\n">>, <<>>), fun(Url) ->
                Hash = binary:encode_hex(crypto:hash(sha256, <<>>), lowercase),
                ?assertEqual({ok, 0, Hash}, z_media_runner_http:download(Url, [], Temp, 0, 2000))
            end)
        after file:delete(Temp) end,
        parallel_connections(),
        io:format("HTTP streaming, JSON, redirects, cancellation and parallel connections verified over TLS.~n")
    after
        case Old of
            undefined -> application:unset_env(zotonic, environment);
            {ok, V} -> application:set_env(zotonic, environment, V)
        end
    end.

request(Url, Timeout) ->
    z_media_runner_http:request(post, {binary_to_list(Url), [], "application/json", <<"{}">>}, Timeout).

%% Four paused result downloads exceed httpc's default two persistent sessions.
%% A JSON model request to the same origin must finish before any download resumes.
parallel_connections() ->
    Dir = os:getenv("MEDIARUNNER_TEST_TLS_DIR"),
    {ok, Listen} = ssl:listen(0, [{certfile, filename:join(Dir, "server.crt")},
        {keyfile, filename:join(Dir, "server.key")}, {active, false}, {reuseaddr, true}]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    Url = iolist_to_binary(["https://localhost:", integer_to_list(Port), "/test"]),
    Parent = self(),
    Server = spawn_link(fun() -> accept_parallel(Listen, Parent, 5) end),
    Paths = [z_tempfile:new() || _ <- lists:seq(1, 4)],
    Clients = [spawn_monitor(fun() ->
        Parent ! {download, self(), z_media_runner_http:download(Url, [], Path, 2, 10000)}
    end) || Path <- Paths],
    try
        Peers = [receive {paused, Peer} -> Peer after 5000 -> error(parallel_download_blocked) end
            || _ <- Paths],
        ?assertEqual({ok, #{<<"outcome">> => <<"accepted">>}},
            z_media_runner_protocol:request(Url, <<"test">>, #{}, 2000)),
        [Peer ! resume || Peer <- Peers],
        Hash = binary:encode_hex(crypto:hash(sha256, <<"ok">>), lowercase),
        lists:foreach(fun({Pid, Ref}) ->
            receive {download, Pid, Result} -> ?assertEqual({ok, 2, Hash}, Result)
            after 5000 -> error(download_timeout) end,
            receive {'DOWN', Ref, process, Pid, normal} -> ok end
        end, Clients)
    after
        ssl:close(Listen),
        unlink(Server),
        exit(Server, kill),
        [begin exit(Pid, kill), demonitor(Ref, [flush]) end || {Pid, Ref} <- Clients],
        [file:delete(Path) || Path <- Paths]
    end.

accept_parallel(_Listen, _Parent, 0) -> ok;
accept_parallel(Listen, Parent, Left) ->
    {ok, Transport} = ssl:transport_accept(Listen, 5000),
    Handler = spawn_link(fun() ->
        receive {socket, S} ->
            {ok, Socket} = ssl:handshake(S, 5000),
            {ok, Request} = ssl:recv(Socket, 0, 5000),
            case iolist_to_binary(Request) of
                <<"GET ", _/binary>> ->
                    ok = ssl:send(Socket, response(200, <<"Content-Length: 2\r\n">>, <<"o">>)),
                    Parent ! {paused, self()},
                    receive resume -> ssl:send(Socket, <<"k">>) after 10000 -> ok end;
                _ ->
                    Body = <<"{\"status\":\"ok\",\"result\":{\"outcome\":\"accepted\"}}">>,
                    ssl:send(Socket, response(200,
                        ["Content-Length: ", integer_to_list(byte_size(Body)), "\r\n"], Body))
            end,
            await_closed(Socket),
            ssl:close(Socket)
        end
    end),
    ok = ssl:controlling_process(Transport, Handler),
    Handler ! {socket, Transport},
    accept_parallel(Listen, Parent, Left - 1).

response(Code, Headers, Body) ->
    ["HTTP/1.1 ", integer_to_list(Code), " Test\r\nConnection: close\r\n", Headers, "\r\n", Body].

with_server(Response, Test) ->
    Dir = os:getenv("MEDIARUNNER_TEST_TLS_DIR"),
    {ok, Listen} = ssl:listen(0, [{certfile, filename:join(Dir, "server.crt")},
        {keyfile, filename:join(Dir, "server.key")}, {active, false}, {reuseaddr, true}]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    {Pid, Monitor} = spawn_monitor(fun() ->
        {ok, Transport} = ssl:transport_accept(Listen, 5000),
        {ok, Socket} = ssl:handshake(Transport, 5000),
        try
            {ok, _} = ssl:recv(Socket, 0, 5000),
            _ = ssl:send(Socket, Response),
            %% Closing the client socket must release the server promptly.
            await_closed(Socket)
        after ssl:close(Socket) end
    end),
    try
        Test(iolist_to_binary(["https://localhost:", integer_to_list(Port), "/test"])),
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 3000 -> error(connection_not_closed) end
    after
        ssl:close(Listen),
        exit(Pid, kill),
        demonitor(Monitor, [flush])
    end.

await_closed(Socket) ->
    case ssl:recv(Socket, 0, 3000) of
        {ok, _} -> await_closed(Socket);
        {error, closed} -> ok;
        {error, Reason} -> error(Reason)
    end.
