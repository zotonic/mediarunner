%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Cache source files and successful results by hash with per-user isolation and LRU eviction.
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

-module(mediarunner_cache).

-moduledoc("
Source and output blobs live on disk; result manifests live in PostgreSQL, isolated by OAuth
user. Inputs are pinned until processing finishes; outputs until receipt or retention expiry.
The queue coordinator serializes blob admission and eviction. Workers read and pin blobs
concurrently, protected by the recently-used grace period.
").
-export([upload/3, cleanup_uploads/2]).
-export([
    prepare/3,
    pin/3,
    release/2,
    read/3,
    result/3,
    put_result/4,
    stats/1,
    strip/1
]).

-spec strip(map()) -> map().
strip(#{<<"files">> := Files} = Job) ->
    Job#{<<"files">> => [maps:remove(<<"data">>, F) || F <- Files]}.

-spec prepare(map(), integer(), z:context()) -> ok | {error, term()}.
prepare(#{<<"files">> := Files}, Owner, Context) ->
    Hashes = lists:usort([H || #{<<"sha256">> := H} <- Files]),
    Missing = [H || H <- Hashes, not source_present(Owner, H, Context)],
    case Missing of
        [] -> ok;
        _ ->
            {error, {missing, Missing}}
    end.

%% All upload mutations run in the queue coordinator, serialized with admission
%% and eviction. Reservations account for the full size before accepting bytes.
-spec upload(term(), integer(), z:context()) -> term().
upload({reserve, Hash, Size}, Owner, Context) ->
    case source_present(Owner, Hash, Context) of
        true ->
            {ok, present};
        false ->
            reserve(Hash, Size, Owner, source, Context)
    end;
%% Result writers are already bounded by the worker pool. They must not compete
%% with incoming uploads for transfer slots, but still obey cache byte/item limits.
upload({reserve_result, Hash, Size}, Owner, Context) ->
    case source_present(Owner, Hash, Context) of
        true ->
            {ok, present};
        false ->
            reserve(Hash, Size, Owner, result, Context)
    end;
upload({claim, Hash, Token}, Owner, Context) ->
    case z_db:q("
        update mediarunner_cache
        set upload_started=true,upload_expires=$4+3600
        where owner_id=$1
          and kind='file'
          and hash=$2
          and upload_token=$3
          and not complete
          and not upload_started
          and upload_expires>$4
        returning path,size,upload_expires",
        [Owner, Hash, Token, erlang:system_time(second)], Context)
    of
        [{Path, Size, Expires}] ->
            {ok, Path, Size, Expires};
        [] ->
            {error, conflict}
    end;
upload({complete, Hash, Token}, Owner, Context) ->
    case z_db:q("
        update mediarunner_cache
        set complete=true,upload_token=null,upload_expires=null,used=$4
        where owner_id=$1
          and kind='file'
          and hash=$2
          and upload_token=$3
          and upload_started
          and not complete
          and upload_expires>$5",
        [Owner, Hash, Token, erlang:system_time(microsecond), erlang:system_time(second)], Context)
    of
        1 -> ok;
        _ ->
            {error, conflict}
    end;
upload({abort, Hash, Token}, Owner, Context) ->
    delete_paths(z_db:q("
        delete from mediarunner_cache
        where owner_id=$1
          and kind='file'
          and hash=$2
          and upload_token=$3
          and not complete
        returning path",
        [Owner, Hash, Token], Context)),
    ok.

reserve(Hash, Size, Owner, Kind, Context) ->
    Now = erlang:system_time(second),
    case z_db:q1("
        select count(*)
        from mediarunner_cache
        where owner_id=$1
          and kind='file'
          and hash=$2
          and not complete
          and upload_expires>$3", [Owner, Hash, Now], Context)
    of
        1 ->
            {error, conflict};
        0 ->
            %% Remove expired reservations or metadata whose file has disappeared.
            delete_paths(z_db:q("
                delete from mediarunner_cache
                where owner_id=$1
                  and kind='file'
                  and hash=$2
                returning path",
                [Owner, Hash], Context)),
            case admission_room(Kind, Size, Owner, Context) of
                ok ->
                    Token = binary:encode_hex(crypto:strong_rand_bytes(32), lowercase),
                    Dir = z_path:files_subdir_ensure("mediarunner", Context),
                    ok = file:change_mode(Dir, 8#700),
                    Path = filename:join(Dir, <<Hash/binary, ".", Token/binary>>),
                    z_db:q("
                        insert into mediarunner_cache (owner_id,kind,hash,data,size,used,path,complete,upload_token,upload_expires)
                        values ($1,'file',$2,$3,$4,$5,$6,false,$7,$8)",
                        [Owner, Hash, <<>>, Size, erlang:system_time(microsecond), Path, Token, Now + 60],
                        Context),
                    {ok, Token};
                Error ->
                    Error
            end
    end.

admission_room(source, Size, Owner, Context) ->
    upload_room(Size, Owner, Context);
admission_room(result, Size, Owner, Context) ->
    room(Size, 1, Owner, [], Context).

%% Limit simultaneous upload reservations as well as their total disk footprint.
upload_room(Size, Owner, Context) ->
    Count = z_db:q1("
        select count(*)
        from mediarunner_cache
        where not complete", Context),
    Limit = case m_site:get(mediarunner_uploads, Context) of
        N when is_integer(N), N > 0 ->
            N;
        _ ->
            20
    end,
    case Count < Limit of
        true ->
            room(Size, 1, Owner, [], Context);
        false ->
            {error, full}
    end.

%% A restart invalidates unfinished uploads. Periodic cleanup bounds abandoned
%% reservations and partial files; unique paths keep late writers isolated.
-spec cleanup_uploads(boolean(), z:context()) -> ok.
cleanup_uploads(Restart, Context) ->
    delete_paths(z_db:q("
        delete from mediarunner_cache
        where not complete
          and ($1 or upload_expires<=$2)
        returning path",
        [Restart, erlang:system_time(second)], Context)),
    ok.

delete_paths(Rows) ->
    lists:foreach(fun
        ({undefined}) -> ok;
        ({Path}) ->
            file:delete(Path)
    end, Rows).

source_present(Owner, Hash, Context) ->
    case read(#{<<"sha256">> => Hash}, Owner, Context) of
        {ok, _} -> true;
        {error, missing} ->
            false
    end.

-spec pin(binary(), map(), z:context()) -> ok.
pin(Id, #{<<"files">> := Files}, Context) ->
    lists:foreach(
        fun(H) ->
            z_db:q("
                insert into mediarunner_job_file (job_id,owner_id,hash) select id,owner_id,$2
                from mediarunner_job
                where id=$1
                on conflict do nothing",
                [Id, H],
                Context
            )
        end,
        lists:usort([H || #{<<"sha256">> := H} <- Files])
    ),
    ok.

-spec release(binary(), z:context()) -> ok.
release(Id, Context) ->
    z_db:q("
        delete from mediarunner_job_file
        where job_id=$1", [Id], Context),
    ok.

-spec read(map(), integer(), z:context()) -> {ok, {file, file:filename_all()}} | {error, missing}.
read(#{<<"sha256">> := H}, Owner, Context) ->
    case z_db:q("
        update mediarunner_cache
        set used=$3
        where owner_id=$1
          and kind='file'
          and hash=$2
          and complete
          and path is not null
        returning path,size",
        [Owner, H, erlang:system_time(microsecond)], Context)
    of
        [{Path, Size}] ->
            case filelib:is_regular(Path) andalso filelib:file_size(Path) =:= Size of
                true ->
                    {ok, {file, Path}};
                false ->
                    {error, missing}
            end;
        [] ->
            {error, missing}
    end.

-spec result(map(), integer(), z:context()) -> {ok, map()} | {error, missing}.
result(Job, Owner, Context) ->
    case get(Owner, <<"result">>, result_key(Job, Context), Context) of
        {ok, Data} ->
            Result = z_json:decode(Data),
            case prepare(#{<<"files">> => maps:get(<<"files">>, Result, [])}, Owner, Context) of
                ok ->
                    {ok, Result};
                {error, _} ->
                    {error, missing}
            end;
        {error, _} = Error ->
            Error
    end.

-spec put_result(map(), integer(), map(), z:context()) -> ok.
put_result(Job, Owner, #{<<"status">> := <<"ok">>} = Result, Context) ->
    Key = result_key(Job, Context),
    Data = z_json:encode(Result),
    %% A recomputed manifest replaces one whose output blobs were evicted.
    z_db:q("
        delete from mediarunner_cache
        where owner_id=$1
          and kind='result'
          and hash=$2",
        [Owner, Key], Context),
    case room(byte_size(Data), 1, Owner, [], Context) of
        ok ->
            put(Owner, <<"result">>, Key, Data, Context);
        {error, full} ->
            ok
    end;
put_result(_, _, _, _) ->
    ok.

result_key(Job, Context) ->
    %% No callback, deadline or job id in the key. Include code, tools and administrator
    %% cache generation so upgrades cannot silently reuse incompatible results.
    Spec = maps:with(
        [<<"version">>, <<"profile">>, <<"command">>, <<"files">>, <<"timeout">>], strip(Job)
    ),
    Tools = [
        {N, tool_stamp(N)}
     || N <- ["file", "magick", "convert", "identify", "ffmpeg", "ffprobe"]
    ],
    hash(
        term_to_binary(
            {
                Spec,
                z_exec:module_info(md5),
                z_media_runner_protocol:module_info(md5),
                z_config:get(exec_sandbox_profiles, #{}),
                z_media_runner_protocol:callback_limit(),
                z_media_runner_protocol:output_limit(),
                m_site:get(mediarunner_cache_version, Context),
                Tools
            }
        )
    ).

tool_stamp(Name) ->
    case os:find_executable(Name) of
        false -> false;
        Path ->
            {Path, filelib:last_modified(Path), filelib:file_size(Path)}
    end.

hash(Data) ->
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).

get(Owner, Kind, Hash, Context) ->
    case
        z_db:q("
            update mediarunner_cache
            set used=$4
            where owner_id=$1
              and kind=$2
              and hash=$3
            returning data",
            [Owner, Kind, Hash, erlang:system_time(microsecond)],
            Context
        )
    of
        [{Data}] ->
            {ok, Data};
        [] ->
            {error, missing}
    end.

put(Owner, Kind, Hash, Data, Context) ->
    z_db:q("
        insert into mediarunner_cache (owner_id,kind,hash,data,size,used)
        values ($1,$2,$3,$4,$5,$6)
        on conflict (owner_id,kind,hash) do update
        set used=excluded.used",
        [Owner, Kind, Hash, Data, byte_size(Data), erlang:system_time(microsecond)],
        Context
    ),
    ok.

%% Bound bytes AND item count; otherwise empty/tiny files could grow metadata indefinitely.
room(Bytes, Items, Owner, Protected, Context) ->
    #{bytes := Used, items := Count, limit := Limit} = stats(Context),
    NeedBytes = max(0, Used + Bytes - Limit),
    NeedItems = max(0, Count + Items - 10000),
    case NeedBytes =:= 0 andalso NeedItems =:= 0 of
        true ->
            ok;
        false ->
            Candidates = z_db:q("
                select owner_id,kind,hash,size
                from mediarunner_cache c
                where complete
                  and (kind <> 'file' or used < $1)
                  and not exists (
                    select 1
                    from mediarunner_job_file p
                    where c.kind='file'
                      and p.owner_id=c.owner_id
                      and p.hash=c.hash
                )
                order by used,owner_id,kind,hash",
                [erlang:system_time(microsecond) - 3600000000], Context
            ),
            Eligible = [
                E
             || {O, K, H, _} = E <- Candidates,
                not (O =:= Owner andalso K =:= <<"file">> andalso lists:member(H, Protected))
            ],
            case evict(Eligible, NeedBytes, NeedItems, Context) of
                ok ->
                    %% Unlinks can fail, and other processes can consume space
                    %% during eviction. Recheck actual free space before admission.
                    #{bytes := Remaining, items := RemainingItems, limit := CurrentLimit} = stats(Context),
                    case Remaining + Bytes =< CurrentLimit andalso RemainingItems + Items =< 10000 of
                        true -> ok;
                        false -> {error, full}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

evict(_, Bytes, Items, _) when Bytes =< 0, Items =< 0 -> ok;
evict([], _, _, _) ->
    {error, full};
evict([{O, K, H, _Size} | Rest], Bytes, Items, Context) ->
    %% A worker may have refreshed or pinned a candidate since selection. Recheck
    %% while deleting, and count only bytes actually removed from the cache.
    Deleted = z_db:q("
        delete from mediarunner_cache c
        where owner_id=$1
          and kind=$2
          and hash=$3
          and complete
          and (kind <> 'file' or used < $4)
          and not exists (
            select 1
            from mediarunner_job_file p
            where c.kind='file'
              and p.owner_id=c.owner_id
              and p.hash=c.hash
        )
        returning path,size",
        [O, K, H, erlang:system_time(microsecond) - 3600000000], Context),
    delete_paths([{Path} || {Path, _} <- Deleted]),
    Freed = lists:sum([Size || {_, Size} <- Deleted]),
    evict(Rest, Bytes - Freed, Items - length(Deleted), Context).

-spec stats(z:context()) -> map().
stats(Context) ->
    [{Count, Bytes, Stored}] = z_db:q("
        select count(*), coalesce(sum(size),0)::bigint,
            coalesce(sum(size) filter (where kind = 'file' and complete),0)::bigint
        from mediarunner_cache", Context
    ),
    ConfiguredLimit =
        case m_site:get(mediarunner_cache_max_bytes, Context) of
            N when is_integer(N), N > 0 ->
                N;
            _ ->
                107374182400
        end,
    CacheDir = z_path:files_subdir_ensure("mediarunner", Context),
    {Total, Available} = mediarunner_capacity:cache_disk(CacheDir),
    #{
        items => Count,
        bytes => Bytes,
        limit => mediarunner_capacity:cache_limit(ConfiguredLimit, Total, Available, Stored),
        configured_limit => ConfiguredLimit,
        disk_total => Total,
        disk_available => Available
    }.
