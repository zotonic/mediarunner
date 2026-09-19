%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Validate HTTPS callback URLs against the optional endpoint allowlist.
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

-module(mediarunner_callback).

-moduledoc("
Shared callback policy for submission and delivery. Authenticated clients may choose any
HTTPS endpoint unless an explicit allowlist is configured.
").
-export([is_allowed/2]).

-spec is_allowed(term(), term()) -> boolean().
is_allowed(Url, Policy) ->
    z_media_runner_protocol:https_url(Url) andalso
        not maps:is_key(query, uri_string:parse(Url)) andalso
        matches(Url, Policy).

matches(_, undefined) ->
    true;
matches(_, any) ->
    true;
matches(Url, URLs) when is_list(URLs) ->
    lists:any(fun(U) -> z_convert:to_binary(U) =:= Url end, URLs);
matches(_, _) ->
    false.
