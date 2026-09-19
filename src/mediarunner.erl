%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Initialize the media runner site schema and supervise its job coordinator.
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

-module(mediarunner).

-moduledoc("
Dedicated media processing site. OAuth2 clients require use/mediarunner permission. The
PostgreSQL queue survives site and node restarts.
").
-behaviour(supervisor).
-mod_title("Media runner").
-mod_description("Sandboxed remote media processing").
-mod_prio(100).
-mod_depends([base, authentication, mod_oauth2, admin]).
-mod_schema(2).
-export([start_link/1, init/1, manage_schema/2]).

-spec start_link(list()) -> supervisor:startlink_ret().
start_link(Args) -> supervisor:start_link(?MODULE, Args).

-spec init(list()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Args) ->
    Context = proplists:get_value(context, Args),
    {ok,
        {#{strategy => one_for_one, intensity => 5, period => 10}, [
            #{
                id => mediarunner_queue,
                start => {mediarunner_queue, start_link, [Context]},
                restart => permanent,
                shutdown => 10000,
                type => worker
            }
        ]}}.

-spec manage_schema(term(), z:context()) -> ok.
manage_schema(install, Context) -> mediarunner_store:install(Context);
manage_schema({upgrade, 2}, Context) -> mediarunner_store:install_cache(Context);
manage_schema(_, _) -> ok.
