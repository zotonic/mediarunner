%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Authorize transport-independent media runner control requests over HTTP or MQTT.
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

-module(m_mediarunner_job).
-behaviour(zotonic_model).

-moduledoc("Authenticated control channel. Every operation requires a writable
context with use/mediarunner permission. Payloads and outcomes are identical over
HTTP model APIs and MQTT; source/result bytes use separate streaming endpoints.").

-export([
    m_get/3,
    m_post/3,
    authorize/1,
    validate/2
]).

%% @doc Look up the runner’s local tool capabilities without probing another runner.
-spec m_get(list(binary()), zotonic_model:opt_msg(), z:context()) -> zotonic_model:return().
m_get([<<"capabilities">> | Rest], _Msg, Context) ->
    case authorize(Context) of
        ok ->
            Info = maps:with([available, tool, major, version], z_media_imagemagick:local()),
            {ok, {#{imagemagick => Info}, Rest}};
        {error, _} = Error ->
            Error
    end;
m_get(_, _, _) ->
    {error, unknown_path}.

%% @doc Dispatch authorized control messages without depending on HTTP request state.
-spec m_post(list(binary()), zotonic_model:opt_msg(), z:context()) -> zotonic_model:post_return().
m_post(Path, #{payload := Payload}, Context) when is_map(Payload) ->
    case authorize(Context) of
        ok ->
            control(Path, Payload, Context);
        {error, _} = Error ->
            Error
    end;
m_post(_, _, _) ->
    {error, payload}.

%% @doc Require an authenticated consumer with write permission, also for direct model calls.
-spec authorize(z:context()) -> ok | {error, eacces}.
authorize(Context) ->
    case z_auth:is_auth(Context) andalso not z_acl:is_read_only(Context)
            andalso z_acl:is_allowed(use, mediarunner, Context) of
        true -> ok;
        false ->
            {error, eacces}
    end.

control([<<"submit">>], Job, Context) ->
    case validate(Job, m_site:get(mediarunner_callback_urls, Context)) of
        ok ->
            case mediarunner_queue:submit(Job, z_acl:user(Context), Context) of
                {ok, _} ->
                    outcome(accepted);
                {error, {missing, Hashes}} ->
                    {ok, #{outcome => missing, missing => Hashes}};
                {error, Reason} ->
                    outcome(Reason)
            end;
        {error, _} ->
            outcome(invalid_job)
    end;
control([<<"reserve">>], #{<<"hash">> := Hash, <<"size">> := Size}, Context)
        when is_integer(Size), Size >= 0 ->
    case valid_hash(Hash) andalso Size =< z_media_runner_protocol:input_limit() of
        true ->
            case mediarunner_queue:upload({reserve, Hash, Size}, z_acl:user(Context), Context) of
                {ok, present} ->
                    outcome(present);
                {ok, Token} ->
                    {ok, #{outcome => upload, upload_token => Token}};
                {error, conflict} ->
                    outcome(busy);
                {error, Reason} ->
                    outcome(Reason)
            end;
        false ->
            {error, payload}
    end;
control([<<"received">>], #{<<"id">> := Id}, Context) when is_binary(Id), byte_size(Id) =< 64 ->
    case z_db:q1("
        select count(*)
        from mediarunner_job
        where id=$1
          and owner_id=$2
          and status='completed'",
            [Id, z_acl:user(Context)], Context) of
        1 ->
            ok = mediarunner_cache:release(Id, Context),
            outcome(received);
        0 ->
            {error, enoent}
    end;
control(_, _, _) ->
    {error, unknown_path}.

outcome(Outcome) ->
    {ok, #{outcome => Outcome}}.

valid_hash(Hash) when is_binary(Hash), byte_size(Hash) =:= 64 ->
    re:run(Hash, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
valid_hash(_) -> false.

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
        true = byte_size(z_json:encode(Job)) =< 1048576,
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
        _:_ ->
            {error, invalid_job}
    end;
validate(_, _) ->
    {error, invalid_job}.
