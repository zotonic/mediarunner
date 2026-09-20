%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Size processing capacity from CPU and memory limits and configure jobs regulation.
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

-module(mediarunner_capacity).

-moduledoc("
Conservative processing capacity from online schedulers and available memory, capped by
container quotas when exposed. Keep one CPU and 25% of available memory for Zotonic and
the OS. Unknown memory means one worker.
").
-export([snapshot/1, workers/3, queue/1, queue/2, configure/2]).

-spec snapshot(z:context()) -> map().
snapshot(Context) ->
    Cores = min(erlang:system_info(schedulers_online), cpu_quota()),
    Available = available_memory(),
    Budget =
        case m_site:get(mediarunner_memory_per_worker, Context) of
            N when is_integer(N), N > 0 -> N;
            _ -> 4294967296
        end,
    Limit =
        case m_site:get(mediarunner_workers, Context) of
            W when is_integer(W), W > 0, W =< 32 -> W;
            _ -> workers(Cores, Available, Budget)
        end,
    Ffmpeg = case m_site:get(mediarunner_ffmpeg_workers, Context) of
        2 -> 2;
        _ -> 1
    end,
    #{workers => Limit, ffmpeg_workers => Ffmpeg, cores => Cores,
        available_memory => Available, memory_per_worker => Budget}.

-spec workers(pos_integer(), non_neg_integer(), pos_integer()) -> pos_integer().
workers(Cores, Available, PerWorker) when
    is_integer(Cores), Cores > 0,
    is_integer(Available), Available >= 0,
    is_integer(PerWorker), PerWorker > 0
->
    max(1, min(32, min(max(1, Cores - 1), Available * 3 div 4 div PerWorker))).

-spec queue(z:context()) -> term().
queue(Context) -> queue(run, Context).

%% @doc Keep long ffmpeg commands independent of the general processing counter.
-spec queue(run | ffmpeg, z:context()) -> term().
queue(run, Context) -> {mediarunner_processing, z_context:site(Context)};
queue(ffmpeg, Context) -> {mediarunner_ffmpeg, z_context:site(Context)}.

-spec configure(map(), z:context()) -> ok.
configure(#{workers := Limit, ffmpeg_workers := Ffmpeg} = Capacity, Context) ->
    ok = configure_queue(queue(run, Context), Limit),
    ok = configure_queue(queue(ffmpeg, Context), Ffmpeg),
    application:set_env(z_context:site(Context), mediarunner_capacity, Capacity).

configure_queue(Name, Limit) ->
    case jobs:queue_info(Name) of
        undefined ->
            ok = jobs:add_queue(Name, [
                {link, self()},
                {max_size, 32},
                {max_time, 5000},
                {regulators, [{counter, [{limit, Limit}, {modifiers, [{cpu, 10}, {memory, 10}]}]}]}
            ]);
        _ ->
            ok = jobs:modify_counter(
                {counter, Name, 1},
                [{limit, Limit}, {modifiers, [{cpu, 10}, {memory, 10}]}]
            )
    end.

available_memory() ->
    Data =
        try
            memsup:get_system_memory_data()
        catch
            _:_ -> []
        end,
    Reclaimable = lists:sum([
        proplists:get_value(K, Data, 0)
     || K <- [free_memory, cached_memory, buffered_memory]
    ]),
    Host = proplists:get_value(available_memory, Data, Reclaimable),
    case memory_quota() of
        undefined -> Host;
        Bytes when Host =:= 0 -> Bytes;
        Bytes -> min(Host, Bytes)
    end.

%% Container memory limits are detected through Linux cgroups (v2, then v1).
%% On other systems, or when these files are unavailable, return undefined so
%% available_memory/0 uses host memory reported by memsup. Unknown host memory
%% falls back to one worker.
memory_quota() ->
    case remaining("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.current") of
        undefined ->
            remaining(
                "/sys/fs/cgroup/memory/memory.limit_in_bytes",
                "/sys/fs/cgroup/memory/memory.usage_in_bytes"
            );
        N ->
            N
    end.

remaining(LimitFile, UsedFile) ->
    case {integer_file(LimitFile), integer_file(UsedFile)} of
        {Limit, Used} when is_integer(Limit), is_integer(Used), Limit < 1152921504606846976 ->
            max(0, Limit - Used);
        _ ->
            undefined
    end.

integer_file(Path) ->
    try
        {ok, Data} = file:read_file(Path),
        binary_to_integer(string:trim(Data))
    catch
        _:_ -> undefined
    end.

cpu_quota() ->
    try
        {ok, Data} = file:read_file("/sys/fs/cgroup/cpu.max"),
        [Quota, Period] = binary:split(string:trim(Data), <<" ">>, [global, trim_all]),
        max(1, binary_to_integer(Quota) div binary_to_integer(Period))
    catch
        _:_ ->
            case
                {
                    integer_file("/sys/fs/cgroup/cpu/cpu.cfs_quota_us"),
                    integer_file("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
                }
            of
                {Q, P} when is_integer(Q), Q > 0, is_integer(P), P > 0 -> max(1, Q div P);
                _ -> erlang:system_info(schedulers_online)
            end
    end.
