%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Authorize media job submissions and admit validated jobs to the durable queue.
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

-module(controller_mediarunner_jobs).

-moduledoc("
Job submission using Zotonic request authentication. mod_oauth2 handles token decoding and
logon; this controller requires a writable authenticated context and use/mediarunner
permission.
").
-export([
    allowed_methods/1,
    content_types_accepted/1,
    content_types_provided/1,
    is_authorized/1,
    process/4,
    validate/2
]).
allowed_methods(Context) -> {[<<"POST">>], Context}.
content_types_accepted(Context) -> {[{<<"application">>, <<"json">>, []}], Context}.
content_types_provided(Context) -> content_types_accepted(Context).
is_authorized(Context) ->
    case z_auth:is_auth(Context) of
        false ->
            {{halt, 401}, Context};
        true ->
            case
                not z_acl:is_read_only(Context) andalso z_acl:is_allowed(use, mediarunner, Context)
            of
                true -> {true, Context};
                false -> {{halt, 403}, Context}
            end
    end.
process(_, _, _, Context) ->
    {Body, Context1} = cowmachine_req:req_body(z_media_runner_protocol:body_limit(), Context),
    Parsed =
        try
            z_json:decode(Body)
        catch
            _:_ -> invalid
        end,
    Allowed = m_site:get(mediarunner_callback_urls, Context1),
    case validate(Parsed, Allowed) of
        ok ->
            case mediarunner_queue:submit(Parsed, z_acl:user(Context1), Context1) of
                {ok, _} ->
                    {{halt, 202}, z_context:set_nocache_headers(Context1)};
                {error, {missing, Hashes}} ->
                    Context2 = cowmachine_req:set_resp_body(
                        z_json:encode(#{missing => Hashes}), Context1
                    ),
                    {{halt, 412}, Context2};
                {error, invalid_cache_file} ->
                    {{halt, 400}, Context1};
                {error, unavailable} ->
                    {{halt, 503}, Context1};
                {error, full} ->
                    {{halt, 429}, Context1};
                {error, conflict} ->
                    {{halt, 409}, Context1}
            end;
        {error, _} ->
            {{halt, 400}, Context1}
    end.

-spec validate(term(), term()) -> ok | {error, invalid_job}.
validate(
    #{
        <<"id">> := Id,
        <<"callback_url">> := Url,
        <<"callback_token">> := Secret,
        <<"expires">> := Expires
    } = Job,
    Allowed
) ->
    try
        ok = z_media_runner_protocol:validate(Job),
        true = is_binary(Id) andalso byte_size(Id) >= 16 andalso byte_size(Id) =< 64,
        match = re:run(Id, <<"^[a-zA-Z0-9_-]+$">>, [{capture, none}]),
        true = is_binary(Secret) andalso byte_size(Secret) >= 32 andalso byte_size(Secret) =< 128,
        match = re:run(Secret, <<"^[a-zA-Z0-9+/=_-]+$">>, [{capture, none}]),
        true = mediarunner_callback:is_allowed(Url, Allowed),
        Now = erlang:system_time(second),
        true = is_integer(Expires) andalso Expires > Now andalso Expires =< Now + 86400,
        ok
    catch
        _:_ -> {error, invalid_job}
    end;
validate(_, _) ->
    {error, invalid_job}.
