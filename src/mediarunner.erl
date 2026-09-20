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
-mod_depends([base, authentication, mod_oauth2, mod_acl_user_groups, mod_content_groups, admin]).
-mod_schema(7).

-export([start_link/1, init/1, manage_schema/2, manage_data/2, event/2]).

-include_lib("zotonic_core/include/zotonic.hrl").

-spec start_link(list()) -> supervisor:startlink_ret().
start_link(Args) -> supervisor:start_link(?MODULE, Args).

-spec init(list()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Args) ->
    Context = proplists:get_value(context, Args),
    {ok,
        {
            #{
                strategy => one_for_one,
                intensity => 5,
                period => 10
            },
            [
                #{
                    id => mediarunner_queue,
                    start => {mediarunner_queue, start_link, [Context]},
                    restart => permanent,
                    shutdown => 10000,
                    type => worker
                }
            ]
        }
    }.

-spec manage_schema(term(), z:context()) -> ok.
manage_schema(install, Context) -> mediarunner_store:install(Context);
manage_schema({upgrade, 6}, Context) -> mediarunner_statistics:install(Context);
manage_schema({upgrade, 4}, Context) -> mediarunner_store:install_cache(Context);
manage_schema({upgrade, 3}, Context) -> mediarunner_store:install_cache(Context);
manage_schema({upgrade, 2}, Context) -> mediarunner_store:install_cache(Context);
manage_schema(_, _) -> ok.


%% @doc Install the API consumer group after the ACL and OAuth2 schemas exist.
-spec manage_data(term(), z:context()) -> ok.
manage_data(install, Context) -> m_mediarunner_consumer:install(Context);
manage_data({upgrade, 7}, Context) -> m_mediarunner_consumer:install(Context);
manage_data({upgrade, 5}, Context) -> m_mediarunner_consumer:install(Context);
manage_data(_, _) -> ok.

%% @doc Handle administrator-only consumer dialogs; provisioning checks ACL again.
-spec event(#postback{} | #submit{}, z:context()) -> z:context().
event(#postback{message = consumer_new}, Context) ->
    case z_acl:is_admin(Context) andalso not z_acl:is_read_only(Context) of
        true ->
            z_render:dialog(?__("Add website / consumer", Context),
                "_dialog_mediarunner_consumer_new.tpl", [], Context);
        false ->
            z_render:growl_error(?__("Only administrators can add consumers.", Context), Context)
    end;
event(#submit{message = consumer_create}, Context) ->
    case m_mediarunner_consumer:create(z_context:get_q(<<"name">>, Context), Context) of
        {ok, Consumer} ->
            z_render:dialog(?__("Consumer created", Context),
                "_dialog_mediarunner_consumer_key.tpl",
                [{consumer, Consumer}, {backdrop, static}], Context);
        {error, invalid_name} ->
            z_render:growl_error(?__("Enter a name of 1 to 128 characters.", Context), Context);
        {error, eacces} ->
            z_render:growl_error(?__("Only administrators can add consumers.", Context), Context);
        {error, _} ->
            z_render:growl_error(?__("Could not create the consumer. Please try again.", Context), Context)
    end;
event(#postback{message = {consumer_edit, [{id, Id}]}}, Context) ->
    consumer_dialog(Id, "_dialog_mediarunner_consumer_edit.tpl", ?__("Update consumer", Context), Context);
event(#postback{message = {consumer_delete, [{id, Id}]}}, Context) ->
    consumer_dialog(Id, "_dialog_mediarunner_consumer_delete.tpl", ?__("Delete consumer", Context), Context);
event(#submit{message = {consumer_update, [{id, Id}]}}, Context) ->
    Rotate = z_convert:to_bool(z_context:get_q(<<"rotate">>, Context)),
    case m_mediarunner_consumer:update(Id, z_context:get_q(<<"name">>, Context), Rotate, Context) of
        {ok, #{token := _} = Consumer} ->
            z_render:dialog(?__("New OAuth2 key", Context),
                "_dialog_mediarunner_consumer_key.tpl",
                [{consumer, Consumer}, {backdrop, static}], Context);
        {ok, _} -> z_render:wire({reload, []}, Context);
        {error, invalid_name} ->
            z_render:growl_error(?__("Enter a name of 1 to 128 characters.", Context), Context);
        {error, _} -> consumer_error(Context)
    end;
event(#submit{message = {consumer_delete_confirm, [{id, Id}]}}, Context) ->
    case m_mediarunner_consumer:delete(Id, Context) of
        ok -> z_render:wire({reload, []}, Context);
        {error, _} -> consumer_error(Context)
    end.

consumer_dialog(Id, Template, Title, Context) ->
    case z_acl:is_read_only(Context) of
        true -> consumer_error(Context);
        false ->
            case m_mediarunner_consumer:get(Id, Context) of
                {ok, Consumer} -> z_render:dialog(Title, Template, [{consumer, Consumer}], Context);
                {error, _} -> consumer_error(Context)
            end
    end.

consumer_error(Context) ->
    z_render:growl_error(?__("Could not change the consumer. Check your permissions and try again.", Context), Context).
