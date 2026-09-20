%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Provision isolated API consumers and OAuth2 credentials for administrators.
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

-module(m_mediarunner_consumer).

-moduledoc "Administrator-only provisioning of a dedicated person, group membership and
writable OAuth2 token. Consumers have only use/mediarunner permission. Credentials
are returned only on creation or rotation, never through a model read path.".

-behaviour(zotonic_model).

-export([install/1, create/2, m_get/3, list/1, get/2, update/4, delete/2]).

-include_lib("zotonic_core/include/zotonic.hrl").

%% @doc Install an independent group and its published and draft module permission.
-spec install(Context) -> ok when Context :: z:context().
install(Context) ->
    {ok, _} = z_db:transaction(fun(Ctx) ->
        {ok, GroupId} = install_group(Ctx),
        ContentGroupId = install_content_group(Ctx),
        %% Migrate existing consumer accounts, including those whose key was revoked.
        Users = m_edge:subjects(GroupId, hasusergroup, Ctx),
        lists:foreach(fun
            (1) -> ok;
            (UserId) ->
                {ok, UserId} = m_rsc:update(UserId,
                    #{<<"content_group_id">> => ContentGroupId}, Ctx)
        end, Users),
        {ok, GroupId}
    end, Context),
    m_hierarchy:ensure(content_group, Context),
    m_hierarchy:ensure(acl_user_group, Context),
    mod_acl_user_groups:rebuild(publish, Context),
    mod_acl_user_groups:rebuild(edit, Context),
    ok.

install_group(Context) ->
    case m_rsc:rid(mediarunner_consumers, Context) of
        undefined ->
            {ok, GroupId} = m_rsc:insert(#{
                <<"name">> => <<"mediarunner_consumers">>,
                <<"category_id">> => acl_user_group,
                <<"title">> => ?__("Media runner consumers", Context),
                <<"is_protected">> => true,
                <<"is_published">> => true
            }, Context),
            %% Write only this group's rule into both versions: publishing all ACL
            %% rules here would also publish unrelated administrator draft changes.
            lists:foreach(fun(IsEdit) ->
                {ok, _} = z_db:insert(acl_rule_module, #{
                    <<"acl_user_group_id">> => GroupId,
                    <<"module">> => <<"mediarunner">>,
                    <<"actions">> => <<"use">>,
                    <<"managed_by">> => <<"mediarunner">>,
                    <<"is_edit">> => IsEdit
                }, Context)
            end, [false, true]),
            {ok, GroupId};
        GroupId ->
            {ok, GroupId}
    end.

%% Keep this group outside the public content-group hierarchy. A targeted deny
%% protects anonymous access even if the site has a broad public-view rule.
install_content_group(Context) ->
    case m_rsc:rid(mediarunner_consumer_content, Context) of
        undefined ->
            {ok, Id} = m_rsc:insert(#{
                <<"name">> => <<"mediarunner_consumer_content">>,
                <<"category_id">> => content_group,
                <<"title">> => ?__("Private media runner consumers", Context),
                <<"is_protected">> => true,
                <<"is_published">> => true
            }, Context),
            {ok, Id} = m_rsc:update(Id, #{<<"content_group_id">> => Id}, Context),
            lists:foreach(fun(IsEdit) ->
                lists:foreach(fun({Group, Block, Actions}) ->
                    {ok, _} = z_db:insert(acl_rule_rsc, #{
                        <<"acl_user_group_id">> => m_rsc:rid(Group, Context),
                        <<"content_group_id">> => Id,
                        <<"actions">> => Actions,
                        <<"is_block">> => Block,
                        <<"managed_by">> => <<"mediarunner">>,
                        <<"is_edit">> => IsEdit
                    }, Context)
                end, [
                    {acl_user_group_anonymous, true, <<"view">>},
                    {acl_user_group_managers, false, <<"view,insert,update,link,delete">>}
                ])
            end, [false, true]),
            Id;
        Id -> Id
    end.

%% @doc Atomically create a consumer; reject anonymous, non-admin and read-only callers.
-spec create(Name, Context) -> {ok, map()} | {error, term()} when
    Name :: term(),
    Context :: z:context().
create(Name, Context) ->
    case z_acl:is_admin(Context) andalso not z_acl:is_read_only(Context) of
        true -> create_named(normalize_name(Name), Context);
        false -> {error, eacces}
    end.

normalize_name(Name) when is_binary(Name), byte_size(Name) =< 512 ->
    case unicode:characters_to_list(z_string:trim(Name)) of
        Chars when is_list(Chars), length(Chars) > 0, length(Chars) =< 128 ->
            unicode:characters_to_binary(Chars);
        _ -> undefined
    end;
normalize_name(_) -> undefined.

create_named(undefined, _Context) ->
    {error, invalid_name};
create_named(Name, Context) ->
    case z_db:transaction(fun(Ctx) -> create_consumer(Name, Ctx) end, Context) of
        {ok, _} = Result -> Result;
        _ -> {error, provisioning_failed}
    end.

create_consumer(Name, Context) ->
    GroupId = m_rsc:rid(mediarunner_consumers, Context),
    true = is_integer(GroupId),
    ContentGroupId = m_rsc:rid(mediarunner_consumer_content, Context),
    true = is_integer(ContentGroupId),
    {ok, UserId} = m_rsc:insert(#{
        <<"category_id">> => person,
        <<"content_group_id">> => ContentGroupId,
        <<"title">> => Name,
        <<"is_published">> => true
    }, Context),
    {ok, _} = m_edge:insert(UserId, hasusergroup, GroupId, Context),
    {ok, AppId} = m_oauth2:insert_app(#{
        <<"description">> => Name,
        <<"user_id">> => UserId
    }, Context),
    Token = new_token(AppId, UserId, GroupId, Context),
    {ok, #{name => Name, user_id => UserId, app_id => AppId, token => Token}}.

new_token(AppId, UserId, GroupId, Context) ->
    {ok, TokenId} = m_oauth2:insert_token(AppId, UserId, undefined, #{
        <<"is_read_only">> => false,
        <<"is_full_access">> => false,
        <<"user_groups">> => [GroupId]
    }, Context),
    {ok, Token} = m_oauth2:encode_bearer_token(TokenId, undefined, Context),
    Token.

%% @doc Expose secret-free consumer metadata only to administrators.
-spec m_get(list(), zotonic_model:opt_msg(), z:context()) -> zotonic_model:return().
m_get([<<"list">> | Rest], _Msg, Context) ->
    case list(Context) of
        {ok, Rows} -> {ok, {Rows, Rest}};
        Error -> Error
    end;
m_get(_, _, _) -> {error, unknown_path}.

-spec list(z:context()) -> {ok, list(map())} | {error, term()}.
list(Context) ->
    case z_acl:is_admin(Context) of
        true ->
            case z_db:qmap(consumer_sql() ++ " order by lower(a.description), a.id",
                    consumer_args(Context), Context) of
                {ok, Rows} ->
                    Stats = mediarunner_statistics:snapshot(Context),
                    {ok, [Row#{<<"statistics">> => maps:get(maps:get(<<"user_id">>, Row), Stats, #{})}
                        || Row <- Rows]};
                Error -> Error
            end;
        false -> {error, eacces}
    end.

-spec get(integer(), z:context()) -> {ok, map()} | {error, term()}.
get(Id, Context) ->
    case z_acl:is_admin(Context) of
        true -> find_consumer(Id, false, Context);
        false -> {error, eacces}
    end.

%% Membership and ownership identify consumers created before this management UI.
%% Never expose app secrets or allow a forged id to modify another OAuth2 app.
consumer_sql() ->
    "select a.id, a.user_id, a.description, a.is_enabled from oauth2_app a "
    "where a.user_id <> 1 and exists (select 1 from edge e "
    "where e.subject_id = a.user_id and e.predicate_id = $1 and e.object_id = $2)".

consumer_args(Context) ->
    [m_rsc:rid(hasusergroup, Context), m_rsc:rid(mediarunner_consumers, Context)].

find_consumer(Id, Lock, Context) when is_integer(Id) ->
    Suffix = case Lock of true -> " for update of a"; false -> "" end,
    case z_db:qmap(consumer_sql() ++ " and a.id = $3" ++ Suffix,
            consumer_args(Context) ++ [Id], Context) of
        {ok, [Row]} -> {ok, Row};
        {ok, []} -> {error, enoent};
        Error -> Error
    end;
find_consumer(_, _, _) -> {error, enoent}.

%% @doc Rename a consumer and optionally revoke all its keys and issue a replacement.
-spec update(integer(), term(), boolean(), z:context()) -> {ok, map()} | {error, term()}.
update(Id, Name, Rotate, Context) when is_boolean(Rotate) ->
    mutate(Id, fun(Row, Ctx) ->
        case normalize_name(Name) of
            undefined -> {error, invalid_name};
            Name1 ->
                UserId = maps:get(<<"user_id">>, Row),
                {ok, UserId} = m_rsc:update(UserId, #{<<"title">> => Name1}, Ctx),
                {ok, App} = m_oauth2:get_app(Id, Ctx),
                ok = m_oauth2:update_app(Id, App#{<<"description">> => Name1}, Ctx),
                Consumer = #{app_id => Id, user_id => UserId, name => Name1},
                case Rotate of
                    false -> {ok, Consumer};
                    true ->
                        {ok, _} = m_oauth2:update_app_secret(Id, Ctx),
                        Token = new_token(Id, UserId, m_rsc:rid(mediarunner_consumers, Ctx), Ctx),
                        {ok, Consumer#{token => Token}}
                end
        end
    end, Context).

%% @doc Revoke the consumer and remove its user if no other OAuth2 apps or keys use it.
%% Jobs and cached files retain their owner id and follow the normal retention policy.
-spec delete(integer(), z:context()) -> ok | {error, term()}.
delete(Id, Context) ->
    mutate(Id, fun(Row, Ctx) ->
        UserId = maps:get(<<"user_id">>, Row),
        ok = m_oauth2:delete_app(Id, Ctx),
        case z_db:q1("select exists(select 1 from oauth2_app where user_id=$1) "
                "or exists(select 1 from oauth2_token where user_id=$1)", [UserId], Ctx) of
            false -> ok = m_rsc:delete(UserId, Ctx);
            true -> ok
        end,
        ok
    end, Context).

mutate(Id, Fun, Context) ->
    case z_acl:is_admin(Context) andalso not z_acl:is_read_only(Context) of
        false -> {error, eacces};
        true ->
            case z_db:transaction(fun(Ctx) ->
                case find_consumer(Id, true, Ctx) of
                    {ok, Row} -> Fun(Row, Ctx);
                    Error -> Error
                end
            end, Context) of
                {rollback, _} -> {error, provisioning_failed};
                Result -> Result
            end
    end.
