%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Persist rendered outputs in the disk cache and build authenticated download links.
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

-module(mediarunner_results).

-export([publish/5, links/2]).

%% @doc Move a completed sandbox output into the owner-scoped disk cache before staging cleanup.
%% Outputs use the same content-hash entries as uploaded inputs, so a follow-up
%% job can reuse these bytes without uploading the downloaded result again.
-spec publish(file:filename_all(), map(), binary(), integer(), z:context()) -> map().
publish(Path, #{<<"sha256">> := Hash, <<"size">> := Size} = File, Id, Owner, Context) ->
    Deadline = erlang:monotonic_time(second) + 3600,
    ok = persist(Path, Hash, Size, Owner, Deadline, Context),
    ok = mediarunner_cache:pin(Id, #{<<"files">> => [File]}, Context),
    File.

persist(Path, Hash, Size, Owner, Deadline, Context) ->
    case mediarunner_queue:upload({reserve_result, Hash, Size}, Owner, Context) of
        {ok, present} -> ok;
        {ok, Token} ->
            try
                {ok, Target, Size, _} = mediarunner_queue:upload({claim, Hash, Token}, Owner, Context),
                ok = move(Path, Target),
                ok = mediarunner_queue:upload({complete, Hash, Token}, Owner, Context)
            after
                mediarunner_queue:upload({abort, Hash, Token}, Owner, Context)
            end;
        {error, conflict} ->
            true = erlang:monotonic_time(second) < Deadline,
            timer:sleep(1000),
            persist(Path, Hash, Size, Owner, Deadline, Context);
        {error, Reason} ->
            error({result_cache, Reason})
    end.

move(Source, Target) ->
    ok = file:change_mode(Source, 8#600),
    case file:rename(Source, Target) of
        ok -> ok;
        {error, exdev} ->
            {ok, Fd} = file:open(Target, [write, exclusive, raw, binary]),
            try
                ok = file:change_mode(Target, 8#600),
                {ok, _} = file:copy(Source, Fd),
                file:sync(Fd)
            after
                file:close(Fd)
            end
    end.

%% @doc Resolve download routes afresh, including for cached operation manifests.
-spec links(map(), z:context()) -> map().
links(#{<<"files">> := Files} = Result, Context) ->
    Result#{<<"files">> => [download_link(F, Context) || F <- Files]};
links(Result, _) ->
    Result.

download_link(#{<<"sha256">> := Hash} = File, Context) ->
    Path = z_dispatcher:url_for(mediarunner_result, [{hash, Hash}], Context),
    File#{<<"url">> => z_context:abs_url(Path, Context)}.
