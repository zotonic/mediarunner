%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2026 Marc Worrell
%% @doc Serve authenticated result downloads and release cache pins after client receipt.
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

-module(controller_mediarunner_result).

-export([allowed_methods/1, content_types_provided/1, content_types_accepted/1,
    is_authorized/1, process/4]).

allowed_methods(Context) ->
    case z_context:get(receipt, Context, false) of
        true -> {[<<"POST">>], Context};
        false -> {[<<"GET">>], Context}
    end.

content_types_provided(Context) -> {[{<<"application">>, <<"octet-stream">>, []}], Context}.
content_types_accepted(Context) -> {[{<<"application">>, <<"json">>, []}], Context}.
is_authorized(Context) -> controller_mediarunner_jobs:is_authorized(Context).

%% @doc Serve owner-scoped files with bounded memory, or acknowledge collection of all job outputs.
process(_, _, _, Context0) ->
    Context = z_context:set_nocache_headers(Context0),
    case z_context:get(receipt, Context, false) of
        true -> receipt(Context);
        false -> download(Context)
    end.

download(Context) ->
    Hash = z_context:get_q(<<"hash">>, Context),
    case mediarunner_cache:read(#{<<"sha256">> => Hash}, z_acl:user(Context), Context) of
        {ok, {file, Path}} ->
            %% Open now: eviction may unlink the name, but cannot invalidate this stream.
            case file:open(Path, [read, raw, binary]) of
                {ok, Fd} ->
                    {ok, Size} = file:position(Fd, eof),
                    {ok, 0} = file:position(Fd, bof),
                    {{device, Size, Fd}, Context};
                {error, _} -> {{halt, 404}, Context}
            end;
        {error, missing} -> {{halt, 404}, Context}
    end.

receipt(Context) ->
    Id = z_context:get_q(<<"id">>, Context),
    case z_db:q1("select count(*) from mediarunner_job where id=$1 and owner_id=$2 and status='completed'",
            [Id, z_acl:user(Context)], Context) of
        1 ->
            ok = mediarunner_cache:release(Id, Context),
            {{halt, 204}, Context};
        0 -> {{halt, 404}, Context}
    end.
