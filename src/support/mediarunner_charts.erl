%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Render dashboard throughput charts with the standard SVG chart scomp.
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

-module(mediarunner_charts).

-moduledoc("
Dashboard chart markup from the standard SVG chart scomp. Only call after authorizing
access to the snapshot.
").
-export([render/2]).

-include_lib("zotonic_core/include/zotonic.hrl").

-spec render(map(), z:context()) -> map().
render(#{updated := Updated, hourly := Hourly}, Context) ->
    Hour = Updated div 3600 * 3600,
    Rows = maps:from_list([{maps:get(<<"hour">>, R), R} || R <- Hourly]),
    Hours = [Hour - N * 3600 || N <- lists:seq(24, 0, -1)],
    #{
        completed => chart(
            <<"completed">>,
            ?__("Completed jobs per hour (UTC)", Context),
            <<"#33896f">>,
            Hours,
            Rows,
            Context
        ),
        failed => chart(
            <<"failed">>,
            ?__("Failed jobs per hour (UTC)", Context),
            <<"#c15a34">>,
            Hours,
            Rows,
            Context
        )
    }.

chart(Key, Title, Color, Hours, Rows, Context) ->
    Data = [{hour_label(H), maps:get(Key, maps:get(H, Rows, #{}), 0)} || H <- Hours],
    {ok, Html} = scomp_base_chart:render(
        [
            {type, line},
            {title, Title},
            {data, Data},
            {width, 720},
            {height, 180},
            {color, Color},
            {hide_table, true},
            {aria_describedby, <<"mr-chart-table">>}
        ],
        [],
        Context
    ),
    iolist_to_binary(Html).

hour_label(Timestamp) ->
    {_, {Hour, _, _}} = z_datetime:timestamp_to_datetime(Timestamp),
    iolist_to_binary(io_lib:format("~2..0B:00", [Hour])).
