%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Reserve missing source hashes and stream verified uploads into the disk cache.
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

-module(controller_mediarunner_file).

-moduledoc("
The mediarunner_job model reserves source hashes before any file bytes are sent.
Only the reservation holder may PUT the raw file, once. Requests use the normal OAuth2
login and mediarunner permission. Source contents never pass through JSON or PostgreSQL.
Incomplete uploads remain invisible and are removed on failure, expiry or site restart.
").

-export([
    allowed_methods/1,
    content_types_accepted/1,
    content_types_provided/1,
    is_authorized/1,
    process/4
]).
-include_lib("zotonic_core/include/zotonic.hrl").
allowed_methods(Context) ->
    {[<<"PUT">>], Context}.

content_types_accepted(Context) ->
    {[{<<"application">>, <<"octet-stream">>, []}], Context}.

content_types_provided(Context) ->
    {[{<<"application">>, <<"json">>, []}], Context}.

is_authorized(Context) ->
    case m_mediarunner_job:authorize(Context) of
        ok ->
            {true, Context};
        {error, _} ->
            {{halt, 403}, Context}
    end.

process(Method, _, _, Context) ->
    Hash = z_context:get_q(<<"hash">>, Context),
    case valid_hash(Hash) of
        true ->
            process_file(Method, Hash, z_context:set_nocache_headers(Context));
        false ->
            {{halt, 400}, Context}
    end.

valid_hash(Hash) when is_binary(Hash), byte_size(Hash) =:= 64 ->
    re:run(Hash, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
valid_hash(_) -> false.

process_file(<<"PUT">>, Hash, Context) ->
    Token = cowmachine_req:get_req_header(<<"x-upload-token">>, Context),
    case valid_hash(Token) of
        true ->
            receive_file(Hash, Token, Context);
        false ->
            {{halt, 400}, Context}
    end.

receive_file(Hash, Token, Context) ->
    Owner = z_acl:user(Context),
    case mediarunner_queue:upload({claim, Hash, Token}, Owner, Context) of
        {ok, Path, Size, Expires} ->
            try
                %% The declared size is checked before reading any body bytes.
                Length = cowmachine_req:get_req_header(<<"content-length">>, Context),
                Size = binary_to_integer(Length),
                {ok, Fd} = file:open(Path, [write, exclusive, raw, binary]),
                try
                    ok = file:change_mode(Path, 8#600),
                    {Digest, Context1} = stream(Fd, Size, Expires, crypto:hash_init(sha256), Context),
                    Hash = Digest,
                    ok = file:sync(Fd),
                    case mediarunner_queue:upload({complete, Hash, Token}, Owner, Context1) of
                        ok ->
                            {{halt, 204}, Context1};
                        {error, Reason} ->
                            {{halt, status(Reason)}, Context1}
                    end
                after
                    file:close(Fd)
                end
            catch
                _:_ ->
                    {{halt, 400}, Context}
            after
                %% Does nothing after successful publication; otherwise removes the partial file.
                mediarunner_queue:upload({abort, Hash, Token}, Owner, Context)
            end;
        {error, Reason} ->
            {{halt, status(Reason)}, Context}
    end.

stream(Fd, Left, Expires, State, Context) ->
    true = erlang:system_time(second) < Expires,
    {Next, Chunk, Context1} = cowmachine_req:stream_req_body(1048576, Context),
    Remaining = Left - byte_size(Chunk),
    true = Remaining >= 0,
    ok = file:write(Fd, Chunk),
    Hash = crypto:hash_update(State, Chunk),
    case Next of
        more ->
            stream(Fd, Remaining, Expires, Hash, Context1);
        ok ->
            0 = Remaining,
            {binary:encode_hex(crypto:hash_final(Hash), lowercase), Context1}
    end.

status(conflict) -> 409;
status(full) -> 429;
status(unavailable) -> 503.
