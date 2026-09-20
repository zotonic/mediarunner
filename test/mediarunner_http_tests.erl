%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Test bounded protocol responses over real TLS connections, including error statuses.
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

%% @doc Exercise the real HTTP parser with oversized fixed/chunked bodies and slow peers.
run() ->
    Old = application:get_env(zotonic, environment),
    application:set_env(zotonic, environment, development),
    try
        lists:foreach(fun(Code) ->
            with_server(response(Code, <<"Content-Length: 2\r\n">>, <<"ok">>), fun(Url) ->
                ?assertEqual({ok, Code, <<"ok">>}, request(Url, 2000))
            end),
            with_server(response(Code, <<"Content-Length: 1000000000\r\n">>,
                    binary:copy(<<"x">>, 70000)), fun(Url) ->
                ?assertEqual({error, response_too_large}, request(Url, 2000))
            end),
            %% Never send the remainder of this enormous chunk: rejection must
            %% happen on received bytes, without buffering the complete chunk.
            with_server(response(Code, <<"Transfer-Encoding: chunked\r\n">>,
                    [<<"3b9aca00\r\n">>, binary:copy(<<"x">>, 70000)]), fun(Url) ->
                ?assertEqual({error, response_too_large}, request(Url, 2000))
            end)
        end, [200, 201, 412, 500]),
        with_server(response(200, <<"Transfer-Encoding: chunked\r\n">>,
                <<"2\r\nok\r\n0\r\n\r\n">>), fun(Url) ->
            ?assertEqual({ok, 200, <<"ok">>}, request(Url, 2000))
        end),
        with_server([<<"HTTP/1.1 500 Test\r\nX-Large: ">>, binary:copy(<<"x">>, 70000)],
            fun(Url) ->
                ?assertEqual({error, response_headers_too_large}, request(Url, 2000))
            end),
        with_server(response(200, <<"Content-Length: 100\r\n">>, <<"x">>), fun(Url) ->
            ?assertEqual({error, timeout}, request(Url, 200))
        end),
        with_server(response(302, <<"Location: https://unreachable.invalid/\r\nContent-Length: 0\r\n">>, <<>>),
            fun(Url) -> ?assertEqual({ok, 302, <<>>}, request(Url, 2000)) end),
        %% A download error is rejected at the headers, without reading its body.
        with_server(response(500, <<"Content-Length: 1000000000\r\n">>, <<>>), fun(Url) ->
            ?assertEqual({error, {http_status, 500}},
                z_media_runner_http:download(Url, [], "/tmp/zmr-must-not-create", 1, 2000))
        end),
        io:format("Bounded HTTP bodies, redirects and total deadlines verified over TLS.~n")
    after
        case Old of
            undefined -> application:unset_env(zotonic, environment);
            {ok, V} -> application:set_env(zotonic, environment, V)
        end
    end.

request(Url, Timeout) -> z_media_runner_protocol:request(Url, <<"test">>, #{}, Timeout).
response(Code, Headers, Body) ->
    ["HTTP/1.1 ", integer_to_list(Code), " Test\r\n", Headers, "\r\n", Body].

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
