%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Reconcile disk cache, staged results and PostgreSQL metadata in bounded cleanup batches.
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

-module(mediarunner_cleanup).

-export([start/1, step/2, work_dir/2]).

-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("kernel/include/file.hrl").

%% The coordinator executes one batch per message, serializing decisions with upload
%% reservation/publication and eviction while allowing control requests between batches.
%% File timestamps are used only for unregistered debris; registered blobs use SQL's
%% last-access time and job pins. Never follow symlinks or traverse outside these roots.
-define(BATCH, 50).

-spec work_dir(binary(), z:context()) -> binary().
work_dir(Id, Context) ->
    Root = root("mediarunner-work", Context),
    z_convert:to_binary(filename:join(Root, <<Id/binary, ".", (z_ids:id(32))/binary>>)).

-spec start(z:context()) -> map().
start(Context) ->
    MaxAge = case m_site:get(mediarunner_cache_max_age, Context) of
        N when is_integer(N), N >= 3600 -> N;
        _ -> 604800
    end,
    Now = erlang:system_time(second),
    #{phase => {rows, <<"file">>, none}, cache_root => root("mediarunner", Context), cutoff => (Now - MaxAge) * 1000000,
        orphan_cutoff => Now - 3600, removed_rows => 0, removed_files => 0}.

-spec step(map(), z:context()) -> map() | done.
step(#{phase := {rows, Kind, Cursor}} = State, Context) ->
    Rows = rows(Kind, Cursor, Context),
    Next = lists:foldl(fun(Row, Acc) -> reconcile(Kind, Row, Acc, Context) end, State, Rows),
    case Rows of
        [] when Kind =:= <<"file">> -> Next#{phase => {rows, <<"result">>, none}};
        [] -> disk_phase("mediarunner", Next, Context);
        _ ->
            {Owner, Hash, _, _, _, _} = lists:last(Rows),
            Next#{phase => {rows, Kind, {Owner, Hash}}}
    end;
step(#{phase := {disk, Name, Root, Names}} = State, Context) ->
    {Batch, Rest} = lists:split(min(?BATCH, length(Names)), Names),
    Next = lists:foldl(fun(File, Acc) -> reconcile_disk(Name, Root, File, Acc, Context) end, State, Batch),
    case {Rest, Name} of
        {[], "mediarunner"} -> disk_phase("mediarunner-work", Next, Context);
        {[], "mediarunner-work"} ->
            ?LOG_INFO(#{text => <<"Media runner cache reconciliation completed">>,
                in => mediarunner, removed_rows => maps:get(removed_rows, Next),
                removed_files => maps:get(removed_files, Next)}),
            done;
        _ -> Next#{phase => {disk, Name, Root, Rest}}
    end.

rows(Kind, none, Context) ->
    z_db:q("select owner_id,hash,path,size,used,case when kind='result' then data else null end from mediarunner_cache "
        "where kind=$1 and complete order by owner_id,hash limit $2", [Kind, batch_size(Kind)], Context);
rows(Kind, {Owner, Hash}, Context) ->
    z_db:q("select owner_id,hash,path,size,used,case when kind='result' then data else null end from mediarunner_cache "
        "where kind=$1 and complete and (owner_id,hash)>($2,$3) "
        "order by owner_id,hash limit $4", [Kind, Owner, Hash, batch_size(Kind)], Context).

%% Stdout in a result manifest can be large; decode only one at a time.
batch_size(<<"result">>) -> 1;
batch_size(<<"file">>) -> ?BATCH.

reconcile(<<"file">>, {Owner, Hash, Path, Size, _, _}, State, Context) ->
    Valid = case managed_path(Path, maps:get(cache_root, State)) of
        true -> valid_file(Path, Size);
        false -> false
    end,
    %% The conditional delete rechecks access and pins at mutation time. Invalid
    %% metadata must be removed even if pinned: its bytes are already unavailable.
    Deleted = z_db:q("delete from mediarunner_cache c where owner_id=$1 and kind='file' "
        "and hash=$2 and complete and (not $3 or (used < $4 and not exists "
        "(select 1 from mediarunner_job_file p where p.owner_id=c.owner_id and p.hash=c.hash))) "
        "returning path", [Owner, Hash, Valid, maps:get(cutoff, State)], Context),
    lists:foldl(fun({P}, Acc) ->
        remove_path(P, maps:get(cache_root, State), count(removed_rows, Acc))
    end, State, Deleted);
reconcile(<<"result">>, {Owner, Hash, _, _, _, Data}, State, Context) ->
    Valid = valid_result(Data, Owner, Context),
    N = z_db:q("delete from mediarunner_cache where owner_id=$1 and kind='result' "
        "and hash=$2 and (not $3 or used < $4)",
        [Owner, Hash, Valid, maps:get(cutoff, State)], Context),
    State#{removed_rows => maps:get(removed_rows, State) + N}.

valid_file(Path, Size) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size}} -> true;
        {error, Reason} when Reason =:= enoent; Reason =:= enotdir -> false;
        {ok, _} -> false;
        {error, _} -> true % A transient filesystem error is not evidence of a missing file.
    end.

valid_result(Data, Owner, Context) ->
    Result = try z_json:decode(Data) catch _:_ -> invalid end,
    case Result of
        #{<<"status">> := <<"ok">>, <<"files">> := Files} when is_list(Files) ->
            lists:all(fun(F) -> result_file_present(F, Owner, Context) end, Files);
        _ -> false
    end.

result_file_present(#{<<"sha256">> := Hash, <<"size">> := Size}, Owner, Context)
    when is_binary(Hash), is_integer(Size), Size >= 0
->
    z_db:q1("select count(*) from mediarunner_cache where owner_id=$1 "
        "and kind='file' and hash=$2 and size=$3 and complete", [Owner, Hash, Size], Context) =:= 1;
result_file_present(_, _, _) -> false.

disk_phase(Name, State, Context) ->
    Root = root(Name, Context),
    case file:list_dir(Root) of
        {ok, Names} -> State#{phase => {disk, Name, Root, Names}};
        {error, Reason} ->
            ?LOG_WARNING(#{text => <<"Cannot scan media runner directory">>,
                in => mediarunner, result => error, reason => Reason, directory => Name}),
            State#{phase => {disk, Name, Root, []}}
    end.

reconcile_disk(Name, Root, File, State, Context) ->
    Path = filename:join(Root, z_convert:to_binary(File)),
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Modified}} when Modified < map_get(orphan_cutoff, State) ->
            case registered(Name, Path, File, Context) of
                true -> State;
                false -> remove_path(Path, Root, State)
            end;
        _ -> State
    end.

registered("mediarunner", Path, _, Context) ->
    %% Includes incomplete reservations, so cleanup never races an active writer.
    z_db:q1("select count(*) from mediarunner_cache where path=$1", [Path], Context) > 0;
registered("mediarunner-work", _, File, Context) ->
    [Id | _] = binary:split(z_convert:to_binary(File), <<".">>),
    z_db:q1("select count(*) from mediarunner_job where id=$1 "
        "and status in ('starting','running')", [Id], Context) > 0.

root(Name, Context) ->
    Dir = z_convert:to_binary(z_path:files_subdir_ensure(Name, Context)),
    ok = file:change_mode(Dir, 8#700),
    Dir.

managed_path(Path, Root) when is_binary(Path) ->
    Name = filename:basename(Path),
    filename:dirname(Path) =:= Root andalso Name =/= <<".">> andalso Name =/= <<"..">>;
managed_path(_, _) -> false.

remove_path(Path, Root, State) ->
    case managed_path(Path, Root) of
        true ->
            %% del_dir_r treats symlinks as files, including links at the root path.
            case file:del_dir_r(Path) of
                ok -> count(removed_files, State);
                {error, enoent} -> State;
                {error, Reason} ->
                    ?LOG_WARNING(#{text => <<"Cannot remove abandoned media runner file">>,
                        in => mediarunner, result => error, reason => Reason}),
                    State
            end;
        false -> State
    end.

count(Key, State) -> State#{Key => maps:get(Key, State) + 1}.
