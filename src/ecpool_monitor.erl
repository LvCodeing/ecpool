%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(ecpool_monitor).

-behaviour(gen_server).

%% API
-export([start_link/0, ensure_monitor_started/0, monitor_spec/0]).
-export([reg_worker/0, put_client_global/1, get_client_global/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(DISCOVERY_TAB, ecpool_global_client_discovery).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ensure_monitor_started() ->
    case supervisor:start_child(ecpool_sup, monitor_spec()) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, _} = Error -> Error
    end.

monitor_spec() ->
    #{
        id => ecpool_monitor,
        start => {ecpool_monitor, start_link, []},
        restart => permanent,
        shutdown => brutal_kill,
        type => worker,
        modules => [ecpool_monitor]
    }.

put_client_global(Client) ->
    ets:insert(?DISCOVERY_TAB, {self(), Client}),
    ok.

get_client_global(WorkerPid) ->
    try ets:lookup(?DISCOVERY_TAB, WorkerPid) of
        [] -> {error, ecpool_client_disconnected};
        [{_, undefined}] -> {error, ecpool_client_disconnected};
        [{_, Client}] -> {ok, Client}
    catch
        error:badarg ->
            {error, ecpool_discovery_tab_not_found}
    end.

reg_worker() ->
    gen_server:call(?MODULE, {reg_worker, self()}, infinity).

%%==============================================================================

init([]) ->
    EtsOpts = [named_table, set, public, {read_concurrency, true}],
    _ = ets:new(?DISCOVERY_TAB, EtsOpts),
    {ok, #{workers => #{}}}.

handle_call({reg_worker, WorkerPid}, _From, State = #{workers := Workers}) ->
    NewWorkers =
        case maps:is_key(WorkerPid, Workers) of
            true -> Workers;
            false ->
                Workers#{WorkerPid => erlang:monitor(process, WorkerPid)}
        end,
    {reply, ok, State#{workers => NewWorkers}};

handle_call(Request, _From, State) ->
    logger:error("~p, Unknown message: ~p", [?MODULE, Request]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    logger:error("~p, Unknown message: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info({'DOWN', _MRef, process, WorkerPid, _Reason}, State = #{workers := Workers}) ->
    ets:delete(?DISCOVERY_TAB, WorkerPid),
    {noreply, State#{workers => maps:remove(WorkerPid, Workers)}};

handle_info(Info, State) ->
    logger:error("~p, Unknown message: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%==============================================================================

