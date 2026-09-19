%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Coordinate durable media jobs, regulated workers and independent callback retries.
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

-module(mediarunner_queue).

-moduledoc("
Bounded supervised processing and callback retries. Work is persisted before acceptance. A
crashed worker becomes a visible failure; restarts recover unfinished jobs.
").
-behaviour(gen_server).
-export([start_link/1, submit/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-spec start_link(z:context()) -> gen_server:start_ret().
start_link(Context) -> gen_server:start_link({local, name(Context)}, ?MODULE, Context, []).

-spec submit(map(), integer(), z:context()) -> {ok, binary()} | {error, term()}.
submit(Job, Owner, Context) ->
    try
        gen_server:call(name(Context), {submit, Job, Owner}, 30000)
    catch
        exit:_ -> {error, unavailable}
    end.
name(Context) -> z_utils:name_for_site(?MODULE, Context).

init(Context) ->
    process_flag(trap_exit, true),
    mediarunner_store:recover(Context),
    Capacity = mediarunner_capacity:snapshot(Context),
    %% This site's previous coordinator may have died before jobs saw its DOWN signal.
    jobs:delete_queue(mediarunner_capacity:queue(Context)),
    ok = mediarunner_capacity:configure(Capacity, Context),
    self() ! poll,
    {ok, #{context => z_context:new(Context), active => #{}, ticks => 0, capacity => Capacity}}.
handle_call({submit, Job, Owner}, _From, #{context := Context} = State) ->
    Reply = mediarunner_store:enqueue(Job, Owner, Context),
    {reply, Reply, fill(State)}.
handle_cast(_, State) -> {noreply, State}.
handle_info({cache_result, Job, Owner, Result}, #{context := Context} = State) ->
    %% Caching is an optimization: a cache failure must not overwrite a completed job.
    _ =
        try
            mediarunner_cache:put_result(Job, Owner, Result, Context)
        catch
            _:_ -> error
        end,
    {noreply, State};
handle_info(poll, #{context := Context, ticks := T} = State) ->
    case T rem 3600 of
        0 -> mediarunner_store:cleanup(Context);
        _ -> ok
    end,
    erlang:send_after(1000, self(), poll),
    Capacity =
        case T rem 60 of
            0 ->
                New = mediarunner_capacity:snapshot(Context),
                ok = mediarunner_capacity:configure(New, Context),
                New;
            _ ->
                maps:get(capacity, State)
        end,
    {noreply, fill(State#{ticks => T + 1, capacity => Capacity})};
handle_info({'DOWN', Ref, process, _, Reason}, #{context := Context, active := Active} = State) ->
    case maps:take(Ref, Active) of
        {{Id, Kind, _Pid}, Rest} ->
            case Reason of
                normal -> ok;
                _ -> mediarunner_store:failed(Id, Kind, Context)
            end,
            {noreply, fill(State#{active => Rest})};
        error ->
            {noreply, State}
    end;
handle_info(_, State) ->
    {noreply, State}.
terminate(_, #{active := Active}) ->
    maps:foreach(fun(_, {_, _, Pid}) -> exit(Pid, shutdown) end, Active),
    ok.

fill(#{capacity := #{workers := Limit}} = State) ->
    %% Result delivery must continue even when media processors saturate every slot.
    fill(run, Limit, fill(deliver, 2, State)).
fill(Kind, Limit, #{context := Context, active := Active} = State) ->
    Count = length([ok || {_, K, _} <- maps:values(Active), K =:= Kind]),
    case Count < Limit of
        false ->
            State;
        true ->
            case mediarunner_store:next(Kind, Context) of
                none ->
                    State;
                {Kind, #{<<"id">> := Id} = Job} ->
                    {Pid, Ref} = spawn_opt(fun() -> regulated_work(Kind, Job, Context) end, [
                        link, monitor
                    ]),
                    fill(Kind, Limit, State#{active => Active#{Ref => {Id, Kind, Pid}}})
            end
    end.
regulated_work(deliver, Job, Context) ->
    work(deliver, Job, Context);
regulated_work(run, #{<<"id">> := Id} = Job, Context) ->
    case jobs:ask(mediarunner_capacity:queue(Context)) of
        {ok, Ticket} ->
            try
                mediarunner_store:started(Id, Context),
                work(run, Job, Context)
            after
                jobs:done(Ticket)
            end;
        {error, _} ->
            mediarunner_store:defer(Id, Context)
    end.
work(
    run,
    #{<<"id">> := Id, <<"payload">> := Payload, <<"owner_id">> := Owner, <<"expires">> := Expires},
    Context
) ->
    Job = z_json:decode(Payload),
    {Result, Cached} =
        case Expires > erlang:system_time(second) of
            true ->
                case mediarunner_cache:result(Job, Owner, Context) of
                    {ok, Hit} ->
                        {Hit, true};
                    {error, missing} ->
                        R = z_media_runner_protocol:execute(Job, fun(F) ->
                            mediarunner_cache:read(F, Owner, Context)
                        end),
                        {R, false}
                end;
            false ->
                {#{<<"status">> => <<"error">>, <<"error">> => <<"job_expired">>}, false}
        end,
    mediarunner_store:result(Id, Result, Cached, Context),
    case Cached of
        false -> name(Context) ! {cache_result, Job, Owner, Result};
        true -> ok
    end;
work(
    deliver,
    #{
        <<"id">> := Id,
        <<"callback_url">> := Url,
        <<"callback_token">> := Token,
        <<"result">> := Result,
        <<"expires">> := Expires
    },
    Context
) ->
    Allowed = m_site:get(mediarunner_callback_urls, Context),
    Reply =
        case
            Expires > erlang:system_time(second) andalso
                mediarunner_callback:is_allowed(Url, Allowed)
        of
            true ->
                z_media_runner_protocol:post(
                    <<Url/binary, "?id=", Id/binary>>, Token, z_json:decode(Result)
                );
            false ->
                {ok, 410}
        end,
    mediarunner_store:delivered(Id, Reply, Context).

%% Crash reports must not contain inputs or callback credentials from the last message.
format_status(Status) -> maps:without([message, reason], Status#{state => redacted}).
