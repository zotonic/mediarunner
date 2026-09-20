%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Verify consumer provisioning, OAuth2 permissions, rollback and key rendering.
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

-module(mediarunner_consumer_tests).

-export([run/2]).

-include_lib("eunit/include/eunit.hrl").

%% @doc Exercise provisioning only in the disposable integration site.
run(Url, Context) ->
    Anonymous = z_context:new(mediarunner),
    Admin = z_acl:logon(1, Anonymous),
    ?assertEqual({error, eacces}, m_mediarunner_consumer:create(<<"Denied">>, Anonymous)),
    ?assertEqual({error, eacces}, m_mediarunner_consumer:create(
        <<"Denied">>, z_acl:set_read_only(true, Admin))),
    lists:foreach(fun(Name) ->
        ?assertEqual({error, invalid_name}, m_mediarunner_consumer:create(Name, Admin))
    end, [undefined, [], <<>>, <<"   ">>, binary:copy(<<"x">>, 129)]),
    {ok, #{user_id := UserId, app_id := AppId, token := Token} = Consumer} =
        m_mediarunner_consumer:create(<<"  Example <website>  ">>, Admin),
    try
        ?assertEqual(<<"Example <website>">>, maps:get(name, Consumer)),
        ?assert(z_auth:is_enabled(UserId, Context)),
        {ok, Access} = m_oauth2:decode_bearer_token(Token, Anonymous),
        ?assertEqual(UserId, maps:get(<<"user_id">>, Access)),
        ?assertEqual(false, maps:get(<<"is_read_only">>, Access)),
        ?assertEqual(false, maps:get(<<"is_full_access">>, Access)),
        Groups = maps:get(<<"user_groups">>, Access),
        ?assertEqual([m_rsc:rid(mediarunner_consumers, Context)], Groups),
        UserContext = z_acl:logon(UserId, #{user_groups => Groups}, Anonymous),
        await_permission(UserContext, 100),
        private_content_checks(UserId, Admin, Anonymous),
        ?assertNot(z_acl:is_admin(UserContext)),
        ?assertNot(z_acl:is_allowed(use, mod_admin, UserContext)),
        ?assertEqual({error, eacces}, m_mediarunner_consumer:create(<<"Denied">>, UserContext)),
        %% Through real HTTP middleware: successful authentication and authorization
        %% reach job validation (400), instead of 401 or 403.
        ?assertEqual({ok, 400}, z_media_runner_protocol:post(Url, Token, #{})),
        ?assertNotEqual(1, UserId),
        render_checks(Consumer, Admin, UserContext, Anonymous),
        rollback_check(Admin),
        management_checks(Url, Consumer, Admin, UserContext, Anonymous)
    after
        m_oauth2:delete_app(AppId, Context),
        m_rsc:delete(UserId, Context)
    end.

await_permission(Context, N) when N > 0 ->
    case z_acl:is_allowed(use, mediarunner, Context) of
        true -> ok;
        false -> timer:sleep(100), await_permission(Context, N - 1)
    end;
await_permission(_, 0) -> error(consumer_permission_missing).

render_checks(Consumer, Admin, User, Anonymous) ->
    lists:foreach(fun({Ctx, Expected}) ->
        {Html, _} = z_template:render_block_to_iolist(content, "mediarunner_consumers.tpl", [], Ctx),
        ?assertEqual(Expected, binary:match(iolist_to_binary(Html), <<"Add website / consumer">>) =/= nomatch)
    end, [{Admin, true}, {User, false}, {Anonymous, false},
        {z_acl:set_read_only(true, Admin), false}]),
    lists:foreach(fun(Template) ->
        {Html, _} = z_template:render_to_iolist(Template, [{consumer, Consumer}], Admin),
        Bin = iolist_to_binary(Html),
        ?assertEqual(nomatch, binary:match(Bin, <<"<website>">>))
    end, ["_dialog_mediarunner_consumer_new.tpl", "_dialog_mediarunner_consumer_key.tpl"]),
    {Html, _} = z_template:render_to_iolist("_dialog_mediarunner_consumer_key.tpl", [{consumer, Consumer}], Admin),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(Html), maps:get(token, Consumer))).

rollback_check(Context) ->
    Before = counts(Context),
    meck:new(m_oauth2, [passthrough, no_link]),
    try
        meck:expect(m_oauth2, insert_token, fun(_, _, _, _, _) -> {error, test_failure} end),
        ?assertEqual({error, provisioning_failed},
            m_mediarunner_consumer:create(<<"Rollback consumer">>, Context)),
        ?assertEqual(Before, counts(Context))
    after
        meck:unload(m_oauth2)
    end.

counts(Context) ->
    [z_db:q1("select count(*) from " ++ Table, Context)
        || Table <- ["rsc", "edge", "oauth2_app", "oauth2_token"]].

management_checks(Url, #{app_id := Id, user_id := UserId, token := OldToken}, Admin, User, Anonymous) ->
    ReadOnly = z_acl:set_read_only(true, Admin),
    lists:foreach(fun(Ctx) ->
        ?assertEqual({error, eacces}, m_mediarunner_consumer:update(Id, <<"Denied">>, true, Ctx)),
        ?assertEqual({error, eacces}, m_mediarunner_consumer:delete(Id, Ctx))
    end, [User, Anonymous, ReadOnly]),
    lists:foreach(fun(Ctx) ->
        ?assertEqual({error, eacces}, m_mediarunner_consumer:list(Ctx)),
        ?assertEqual({error, eacces}, m_mediarunner_consumer:get(Id, Ctx)),
        ?assertEqual({error, eacces}, m_mediarunner_consumer:m_get([<<"list">>], undefined, Ctx))
    end, [User, Anonymous]),
    {ok, Rows} = m_mediarunner_consumer:list(ReadOnly),
    ?assert(lists:any(fun(R) -> maps:get(<<"id">>, R) =:= Id end, Rows)),
    lists:foreach(fun(R) ->
        ?assertEqual([<<"description">>, <<"id">>, <<"is_enabled">>, <<"statistics">>, <<"user_id">>], lists:sort(maps:keys(R)))
    end, Rows),
    {ok, OtherApp} = m_oauth2:insert_app(#{<<"description">> => <<"Unrelated">>}, Admin),
    try
        ?assertEqual({error, enoent}, m_mediarunner_consumer:update(OtherApp, <<"No">>, true, Admin)),
        ?assertEqual({error, enoent}, m_mediarunner_consumer:delete(OtherApp, Admin))
    after
        m_oauth2:delete_app(OtherApp, Admin)
    end,
    ?assertEqual({error, invalid_name}, m_mediarunner_consumer:update(Id, <<" ">>, false, Admin)),
    {ok, Renamed} = m_mediarunner_consumer:update(Id, <<"Renamed <website>">>, false, Admin),
    ?assertNot(maps:is_key(token, Renamed)),
    ?assertEqual({ok, 400}, z_media_runner_protocol:post(Url, OldToken, #{})),
    {ok, Row} = m_mediarunner_consumer:get(Id, Admin),
    ?assertEqual(<<"Renamed <website>">>, maps:get(<<"description">>, Row)),
    lists:foreach(fun(Tpl) ->
        {Html, _} = case Tpl of
            "mediarunner_consumers.tpl" -> z_template:render_block_to_iolist(content, Tpl, [], Admin);
            _ -> z_template:render_to_iolist(Tpl, [{consumer, Row}], Admin)
        end,
        Bin = iolist_to_binary(Html),
        ?assertNotEqual(nomatch, binary:match(Bin, <<"Renamed &lt;website&gt;">>)),
        ?assertEqual(nomatch, binary:match(Bin, OldToken))
    end, ["mediarunner_consumers.tpl", "_dialog_mediarunner_consumer_edit.tpl", "_dialog_mediarunner_consumer_delete.tpl"]),
    rotation_rollback(Id, OldToken, Admin),
    {ok, #{token := NewToken}} = m_mediarunner_consumer:update(Id, <<"Renamed">>, true, Admin),
    ?assertNotEqual(OldToken, NewToken),
    ?assertEqual({ok, 401}, z_media_runner_protocol:post(Url, OldToken, #{})),
    ?assertEqual({ok, 400}, z_media_runner_protocol:post(Url, NewToken, #{})),
    ?assertEqual(ok, m_mediarunner_consumer:delete(Id, Admin)),
    ?assertEqual({ok, 401}, z_media_runner_protocol:post(Url, NewToken, #{})),
    ?assertEqual({error, enoent}, m_mediarunner_consumer:get(Id, Admin)),
    ?assertNot(m_rsc:exists(UserId, Admin)),
    ?assertEqual({error, enoent}, m_mediarunner_consumer:delete(Id, Admin)).

rotation_rollback(Id, OldToken, Context) ->
    {ok, Before} = m_mediarunner_consumer:get(Id, Context),
    meck:new(m_oauth2, [passthrough, no_link]),
    try
        meck:expect(m_oauth2, encode_bearer_token, fun(_, _, _) -> {error, test_failure} end),
        ?assertEqual({error, provisioning_failed},
            m_mediarunner_consumer:update(Id, <<"Must roll back">>, true, Context)),
        ?assertEqual({ok, Before}, m_mediarunner_consumer:get(Id, Context)),
        ?assertMatch({ok, _}, m_oauth2:decode_bearer_token(OldToken, Context))
    after
        meck:unload(m_oauth2)
    end.

private_content_checks(UserId, Admin, Anonymous) ->
    Private = m_rsc:rid(mediarunner_consumer_content, Admin),
    ?assert(is_integer(Private)),
    ?assertEqual(Private, m_rsc:p_no_acl(UserId, content_group_id, Admin)),
    ?assertNot(z_acl:rsc_visible(UserId, Anonymous)),
    ?assertNot(z_acl:rsc_visible(Private, Anonymous)),
    ?assert(z_acl:rsc_visible(UserId, Admin)),
    ?assert(z_auth:is_enabled(UserId, Anonymous)),
    %% Simulate a pre-upgrade account and rerun the migration twice.
    {ok, UserId} = m_rsc:update(UserId,
        #{<<"content_group_id">> => m_rsc:rid(default_content_group, Admin)}, Admin),
    ?assert(z_acl:rsc_visible(UserId, Anonymous)),
    ok = m_mediarunner_consumer:install(Admin),
    ok = m_mediarunner_consumer:install(Admin),
    ?assertEqual(Private, m_rsc:p_no_acl(UserId, content_group_id, Admin)),
    ?assertNot(z_acl:rsc_visible(UserId, Anonymous)),
    ?assertEqual(4, z_db:q1("select count(*) from acl_rule_rsc "
        "where content_group_id=$1 and managed_by='mediarunner'", [Private], Admin)),
    %% Check a normal manager account as well as the built-in administrator.
    {ok, ManagerId} = m_rsc:insert(#{<<"category_id">> => person,
        <<"title">> => <<"Disposable manager">>, <<"is_published">> => true}, Admin),
    try
        {ok, _} = m_edge:insert(ManagerId, hasusergroup, acl_user_group_managers, Admin),
        Manager = z_acl:logon(ManagerId, Anonymous),
        ?assert(z_acl:is_admin(Manager)),
        ?assert(z_acl:rsc_visible(UserId, Manager)),
        ?assert(z_acl:rsc_editable(UserId, Manager))
    after
        m_rsc:delete(ManagerId, Admin)
    end.
