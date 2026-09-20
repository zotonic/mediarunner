%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Exercise periodic cache reconciliation, expiry and protection of active work.
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

-module(mediarunner_cleanup_tests).

-export([run/1]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

run(Context) ->
    Queue = whereis(z_utils:name_for_site(mediarunner_queue, Context)),
    wait_idle(Queue, 100),
    ok = sys:suspend(Queue),
    Owner = 999997,
    Root = z_convert:to_binary(z_path:files_subdir_ensure("mediarunner", Context)),
    Outside = z_tempfile:new(),
    ok = file:write_file(Outside, <<"must survive symlink cleanup">>),
    Running = z_ids:id(32),
    Completed = z_ids:id(32),
    Work = mediarunner_cleanup:work_dir(Running, Context),
    Abandoned = mediarunner_cleanup:work_dir(z_ids:id(32), Context),
    Old = erlang:system_time(second) - 7200,
    Orphans = [filename:join(Root, <<"orphan-", (integer_to_binary(N))/binary>>) || N <- lists:seq(1, 60)],
    Fresh = filename:join(Root, <<"fresh-orphan">>),
    try
        insert_job(Running, Owner, <<"running">>, Context),
        insert_job(Completed, Owner, <<"completed">>, Context),
        {Pinned, PinnedPath} = blob(<<"pinned result">>, Owner, Context),
        {Expired, ExpiredPath} = blob(<<"expired source">>, Owner, Context),
        {Missing, MissingPath} = blob(<<"missing output">>, Owner, Context),
        {Damaged, DamagedPath} = blob(<<"wrong size">>, Owner, Context),
        ok = mediarunner_cache:pin(Completed, #{<<"files">> => [Pinned]}, Context),
        ok = mediarunner_store:recover(Context),
        ?assertEqual(1, z_db:q1("select count(*) from mediarunner_job_file where job_id=$1", [Completed], Context)),
        z_db:q("update mediarunner_job set status='running' where id=$1", [Running], Context),
        z_db:q("update mediarunner_cache set used=0 where owner_id=$1", [Owner], Context),
        ok = file:delete(MissingPath),
        ok = file:write_file(DamagedPath, <<"x">>),
        ManifestHash = z_crypto:hex_sha2(<<"broken manifest">>),
        z_db:q("insert into mediarunner_cache(owner_id,kind,hash,data,size,used) values($1,'result',$2,$3,100,$4)",
            [Owner, ManifestHash, z_json:encode(#{<<"status">> => <<"ok">>, <<"files">> => [Missing]}),
                erlang:system_time(microsecond)], Context),
        lists:foreach(fun(P) -> old_file(P, Old) end, Orphans),
        ok = file:write_file(Fresh, <<"new">>),
        ok = file:make_dir(Work),
        ok = file:write_file(filename:join(Work, <<"active-output">>), <<"rendering">>),
        ok = file:write_file_info(Work, #file_info{mtime = Old}, [{time, posix}]),
        ok = file:make_dir(Abandoned),
        ok = file:make_symlink(Outside, filename:join(Abandoned, <<"link">>)),
        ok = file:write_file_info(Abandoned, #file_info{mtime = Old}, [{time, posix}]),
        %% Corrupt administration must never make cleanup remove its root or an
        %% arbitrary file outside it, even when those paths are registered as blobs.
        lists:foreach(fun(Path) ->
            z_db:q("insert into mediarunner_cache(owner_id,kind,hash,data,size,used,path) "
                "values($1,'file',$2,$3,0,0,$4)",
                [Owner, z_crypto:hex_sha2(Path), <<>>, Path], Context)
        end, [<<Root/binary, "/.">>, Outside]),
        %% Start a claim between batches. Its partial file is old and the wrong size,
        %% but an active reservation protects it from both directions of the scan.
        State = mediarunner_cleanup:step(mediarunner_cleanup:start(Context), Context),
        PartialHash = z_crypto:hex_sha2(<<"partial">>),
        {ok, Token} = mediarunner_cache:upload({reserve, PartialHash, 100}, Owner, Context),
        {ok, Partial, _, _} = mediarunner_cache:upload({claim, PartialHash, Token}, Owner, Context),
        old_file(Partial, Old),
        finish(State, Context),
        ?assert(filelib:is_regular(PinnedPath)),
        ?assert(filelib:is_regular(Partial)),
        ?assert(filelib:is_regular(Fresh)),
        ?assert(filelib:is_dir(Work)),
        ?assertNot(filelib:is_dir(Abandoned)),
        ?assert(filelib:is_regular(Outside)),
        ?assert(lists:all(fun(P) -> not filelib:is_file(P) end, Orphans)),
        ?assertNot(filelib:is_file(ExpiredPath)),
        ?assertNot(filelib:is_file(DamagedPath)),
        lists:foreach(fun(F) ->
            ?assertEqual(0, z_db:q1("select count(*) from mediarunner_cache where owner_id=$1 and hash=$2",
                [Owner, maps:get(<<"sha256">>, F)], Context))
        end, [Expired, Missing, Damaged]),
        ?assertEqual(0, z_db:q1("select count(*) from mediarunner_cache where owner_id=$1 and kind='result'", [Owner], Context)),
        %% Expired reservations and result pins become collectible on the next pass.
        z_db:q("update mediarunner_cache set upload_expires=0 where owner_id=$1 and not complete", [Owner], Context),
        ok = mediarunner_cache:cleanup_uploads(false, Context),
        ?assertNot(filelib:is_file(Partial)),
        z_db:q("update mediarunner_job set finished=1 where id=$1", [Completed], Context),
        ok = mediarunner_store:cleanup(Context),
        finish(mediarunner_cleanup:start(Context), Context),
        ?assertNot(filelib:is_file(PinnedPath)),
        %% Exercise the actual queued cleanup entry point, rather than only its steps.
        z_db:q("delete from mediarunner_job where owner_id=$1", [Owner], Context),
        ok = sys:resume(Queue),
        Queue ! cleanup,
        wait_removed(Work, 200),
        io:format("Cache/database reconciliation, batched orphan cleanup and active-work protection verified.~n")
    after
        z_db:q("delete from mediarunner_job where owner_id=$1", [Owner], Context),
        lists:foreach(fun({P}) -> file:delete(P) end,
            z_db:q("delete from mediarunner_cache where owner_id=$1 returning path", [Owner], Context)),
        lists:foreach(fun(P) -> file:del_dir_r(P) end, [Work, Abandoned, Fresh, Outside | Orphans]),
        sys:resume(Queue)
    end.

blob(Data, Owner, Context) ->
    Hash = z_crypto:hex_sha2(Data),
    F = #{<<"id">> => 1, <<"sha256">> => Hash, <<"size">> => byte_size(Data)},
    {ok, Token} = mediarunner_cache:upload({reserve, Hash, byte_size(Data)}, Owner, Context),
    {ok, Path, _, _} = mediarunner_cache:upload({claim, Hash, Token}, Owner, Context),
    ok = file:write_file(Path, Data),
    ok = mediarunner_cache:upload({complete, Hash, Token}, Owner, Context),
    {F, Path}.

insert_job(Id, Owner, Status, Context) ->
    Now = erlang:system_time(second),
    z_db:q("insert into mediarunner_job(id,owner_id,profile,status,request_hash,created,expires,finished) "
        "values($1,$2,'file',$3,$4,$5,$6,$5)", [Id, Owner, Status, <<>>, Now, Now + 600], Context).

old_file(Path, Time) ->
    ok = file:write_file(Path, <<"orphan">>),
    ok = file:write_file_info(Path, #file_info{mtime = Time}, [{time, posix}]).

finish(done, _) -> ok;
finish(State, Context) -> finish(mediarunner_cleanup:step(State, Context), Context).

wait_idle(_, 0) -> error(queue_not_idle);
wait_idle(Queue, N) ->
    case sys:get_state(Queue) of
        #{active := Active} = State when map_size(Active) =:= 0, not is_map_key(cleanup, State) -> ok;
        _ -> timer:sleep(100), wait_idle(Queue, N - 1)
    end.

wait_removed(_, 0) -> error(periodic_cleanup_not_completed);
wait_removed(Path, N) ->
    case filelib:is_dir(Path) of
        false -> ok;
        true -> timer:sleep(100), wait_removed(Path, N - 1)
    end.
