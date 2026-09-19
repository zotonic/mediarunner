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
Content-addressed PostgreSQL LRU cache, isolated by OAuth user. Queue inputs are pinned
until processing finishes. Only the queue coordinator writes/evicts; workers can read
concurrently.
").
-export([prepare/3, pin/3, release/2, read/3, result/3, put_result/4, stats/1, strip/1]).

-spec strip(map()) -> map().
strip(#{<<"files">> := Files} = Job) ->
    Job#{<<"files">> => [maps:remove(<<"data">>, F) || F <- Files]}.

-spec prepare(map(), integer(), z:context()) -> ok | {error, term()}.
prepare(#{<<"files">> := Files}, Owner, Context) ->
    try
        Hashes = lists:usort([H || #{<<"sha256">> := H} <- Files]),
        Present = [H || H <- Hashes, present(Owner, <<"file">>, H, Context)],
        Supplied = maps:from_list([decode(F) || F <- Files, maps:is_key(<<"data">>, F)]),
        Missing = Hashes -- (Present ++ maps:keys(Supplied)),
        case Missing of
            [] ->
                New = maps:without(Present, Supplied),
                Bytes = lists:sum([byte_size(D) || D <- maps:values(New)]),
                case room(Bytes, map_size(New), Owner, Hashes, Context) of
                    ok ->
                        maps:foreach(fun(H, D) -> put(Owner, <<"file">>, H, D, Context) end, New),
                        lists:foreach(
                            fun(H) ->
                                z_db:q(
                                    "update mediarunner_cache set used=$3 where owner_id=$1 and kind='file' and hash=$2",
                                    [Owner, H, erlang:system_time(microsecond)],
                                    Context
                                )
                            end,
                            Present
                        ),
                        ok;
                    {error, _} = Error ->
                        Error
                end;
            _ ->
                {error, {missing, Missing}}
        end
    catch
        _:_ -> {error, invalid_cache_file}
    end.
decode(#{<<"sha256">> := Hash, <<"data">> := Encoded}) ->
    Data = base64:decode(Encoded),
    true = byte_size(Data) =< z_media_runner_protocol:limit(),
    Hash = hash(Data),
    {Hash, Data}.

-spec pin(binary(), map(), z:context()) -> ok.
pin(Id, #{<<"files">> := Files}, Context) ->
    lists:foreach(
        fun(H) ->
            z_db:q(
                "insert into mediarunner_job_file (job_id,owner_id,hash)\n"
                "            select id,owner_id,$2 from mediarunner_job where id=$1 on conflict do nothing",
                [Id, H],
                Context
            )
        end,
        lists:usort([H || #{<<"sha256">> := H} <- Files])
    ),
    ok.

-spec release(binary(), z:context()) -> ok.
release(Id, Context) ->
    z_db:q("delete from mediarunner_job_file where job_id=$1", [Id], Context),
    ok.

-spec read(map(), integer(), z:context()) -> {ok, binary()} | {error, missing}.
read(#{<<"sha256">> := H}, Owner, Context) -> get(Owner, <<"file">>, H, Context).

-spec result(map(), integer(), z:context()) -> {ok, map()} | {error, missing}.
result(Job, Owner, Context) ->
    case get(Owner, <<"result">>, result_key(Job, Context), Context) of
        {ok, Data} -> {ok, z_json:decode(Data)};
        {error, _} = Error -> Error
    end.

-spec put_result(map(), integer(), map(), z:context()) -> ok.
put_result(Job, Owner, #{<<"status">> := <<"ok">>} = Result, Context) ->
    Key = result_key(Job, Context),
    Data = z_json:encode(Result),
    case present(Owner, <<"result">>, Key, Context) of
        true ->
            ok;
        false ->
            case room(byte_size(Data), 1, Owner, [], Context) of
                ok -> put(Owner, <<"result">>, Key, Data, Context);
                {error, full} -> ok
            end
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
            {Spec, z_exec:module_info(md5), z_media_runner_protocol:module_info(md5),
                z_config:get(exec_sandbox_profiles, #{}), z_media_runner_protocol:limit(),
                m_site:get(mediarunner_cache_version, Context), Tools}
        )
    ).
tool_stamp(Name) ->
    case os:find_executable(Name) of
        false -> false;
        Path -> {Path, filelib:last_modified(Path), filelib:file_size(Path)}
    end.
hash(Data) -> binary:encode_hex(crypto:hash(sha256, Data), lowercase).

present(Owner, Kind, Hash, Context) ->
    z_db:q1(
        "select count(*) from mediarunner_cache where owner_id=$1 and kind=$2 and hash=$3",
        [Owner, Kind, Hash],
        Context
    ) =:= 1.
get(Owner, Kind, Hash, Context) ->
    case
        z_db:q(
            "update mediarunner_cache set used=$4 where owner_id=$1 and kind=$2 and hash=$3 returning data",
            [Owner, Kind, Hash, erlang:system_time(microsecond)],
            Context
        )
    of
        [{Data}] -> {ok, Data};
        [] -> {error, missing}
    end.
put(Owner, Kind, Hash, Data, Context) ->
    z_db:q(
        "insert into mediarunner_cache (owner_id,kind,hash,data,size,used) values ($1,$2,$3,$4,$5,$6)\n"
        "        on conflict (owner_id,kind,hash) do update set used=excluded.used",
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
            Candidates = z_db:q(
                "select owner_id,kind,hash,size from mediarunner_cache c\n"
                "                where not exists (select 1 from mediarunner_job_file p\n"
                "                    where c.kind='file' and p.owner_id=c.owner_id and p.hash=c.hash)\n"
                "                order by used,owner_id,kind,hash",
                Context
            ),
            Eligible = [
                E
             || {O, K, H, _} = E <- Candidates,
                not (O =:= Owner andalso K =:= <<"file">> andalso lists:member(H, Protected))
            ],
            evict(Eligible, NeedBytes, NeedItems, Context)
    end.
evict(_, Bytes, Items, _) when Bytes =< 0, Items =< 0 -> ok;
evict([], _, _, _) ->
    {error, full};
evict([{O, K, H, Size} | Rest], Bytes, Items, Context) ->
    z_db:q(
        "delete from mediarunner_cache where owner_id=$1 and kind=$2 and hash=$3",
        [O, K, H],
        Context
    ),
    evict(Rest, Bytes - Size, Items - 1, Context).

-spec stats(z:context()) -> map().
stats(Context) ->
    [{Count, Bytes}] = z_db:q(
        "select count(*), coalesce(sum(size),0)::bigint from mediarunner_cache", Context
    ),
    Limit =
        case m_site:get(mediarunner_cache_max_bytes, Context) of
            N when is_integer(N), N > 0 -> N;
            _ -> 1073741824
        end,
    #{items => Count, bytes => Bytes, limit => Limit}.
