%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Provide authorized dashboard snapshots and charts without exposing job secrets.
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

-module(m_mediarunner).

-moduledoc("
Dashboard snapshots, restricted to logged-in users with use/mediarunner permission. Never
returns commands, input/output files, callback URLs or credentials.
").

-behaviour(zotonic_model).

-export([m_get/3]).

-spec m_get(list(), zotonic_model:opt_msg(), z:context()) -> zotonic_model:return().
m_get([<<"status">> | Rest], Msg, Context) ->
    case z_auth:is_auth(Context) andalso z_acl:is_allowed(use, mediarunner, Context) of
        true ->
            Filter =
                case Msg of
                    #{payload := #{<<"filter">> := F}} when is_binary(F), byte_size(F) =< 16 ->
                        F;
                    _ ->
                        <<>>
                end,
            Snapshot = mediarunner_store:snapshot(Filter, Context),
            {ok, {Snapshot#{charts => mediarunner_charts:render(Snapshot, Context),
                sandbox => mediarunner_sandbox:status(Context)}, Rest}};
        false ->
            {error, eacces}
    end;
m_get([<<"sandbox">> | Rest], _Msg, Context) ->
    case z_auth:is_auth(Context) andalso z_acl:is_allowed(use, mediarunner, Context) of
        true ->
            {ok, {mediarunner_sandbox:status(Context), Rest}};
        false ->
            {error, eacces}
    end;
m_get(_, _, _) ->
    {error, unknown_path}.
