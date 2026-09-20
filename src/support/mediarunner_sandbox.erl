%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Track OS sandbox availability and provide translated administrator status messages.
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

-module(mediarunner_sandbox).
-export([refresh/1, status/1]).
-include_lib("zotonic_core/include/zotonic.hrl").

%% @doc Probe on startup and periodically, keeping dashboard requests lightweight.
-spec refresh(z:context()) -> ok.
refresh(Context) ->
    Result = z_exec:sandbox_status(),
    State = case Result of
        {ok, _} -> available;
        {error, {sandbox_unsupported, _}} -> unsupported;
        {error, _} -> error
    end,
    case {State, m_site:get(mediarunner_sandbox_status, Context)} of
        {unsupported, Previous} when Previous =/= unsupported ->
            ?LOG_NOTICE(#{text => <<"OS sandbox unsupported; media jobs will run without isolation">>,
                in => mediarunner, os => os:type(), reason => sandbox_unsupported});
        {error, Previous} when Previous =/= error ->
            ?LOG_ERROR(#{text => <<"Media runner sandbox setup failed">>,
                in => mediarunner, result => error, reason => Result});
        _ -> ok
    end,
    application:set_env(z_context:site(Context), mediarunner_sandbox_status, State).

%% @doc Describe the runner's actual policy, independently of the local exec_sandbox opt-out.
-spec status(z:context()) -> map().
status(Context) ->
    State = m_site:get(mediarunner_sandbox_status, Context),
    Message = case State of
        available -> ?__("OS sandbox available. Media jobs run with sandbox isolation.", Context);
        unsupported -> ?__("OS sandbox unsupported. Media jobs run without sandbox isolation.", Context);
        error -> ?__("Sandbox setup failed. Media processing is blocked; check the server logs.", Context);
        _ -> ?__("OS sandbox status has not been checked yet.", Context)
    end,
    #{state => State, message => Message}.
