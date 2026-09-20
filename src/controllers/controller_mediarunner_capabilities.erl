%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Report the runner’s installed ImageMagick version to authorized clients.
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

-module(controller_mediarunner_capabilities).

-export([allowed_methods/1, content_types_accepted/1, content_types_provided/1,
    is_authorized/1, process/4]).

allowed_methods(Context) -> {[<<"POST">>], Context}.
content_types_accepted(Context) -> {[{<<"application">>, <<"json">>, []}], Context}.
content_types_provided(Context) -> {[{<<"application">>, <<"json">>, []}], Context}.
is_authorized(Context) -> controller_mediarunner_jobs:is_authorized(Context).

%% @doc Probe locally to avoid recursively querying a configured remote runner.
process(_, _, _, Context) ->
    Info = maps:with([available, tool, major, version], z_media_imagemagick:local()),
    Body = z_json:encode(#{imagemagick => Info}),
    Context1 = z_context:set_nocache_headers(Context),
    {{halt, 200}, cowmachine_req:set_resp_body(Body, Context1)}.
