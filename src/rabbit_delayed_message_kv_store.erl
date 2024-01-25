%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% NOTE that this module uses os:timestamp/0 but in the future Erlang
%% will have a new time API.
%% See:
%% https://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/erlang.html#now-0
%% and
%% https://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/time_correction.html

-module(rabbit_delayed_message_kv_store).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-behaviour(gen_server).

-export([start_link/0, leveled_bookie_start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([
         do_write/2,
         do_delete/1,
         do_take/1
         ]).

-record(state,
        {kv_store_pid
        }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

leveled_bookie_start_link() ->
    DataDir = filename:join(
                [rabbit:data_dir(), "dmx", node()]),
    Result = {ok, Pid} = leveled_bookie:book_start([{root_path, DataDir},
                                                    {log_level, error}]),
    register(rabbit_leveled_bookie, Pid),
    Result.

init([]) ->
    {ok, #state{kv_store_pid = rabbit_leveled_bookie}}.


do_write(Key, Value) ->
    gen_server:cast(?MODULE, {write, Key, Value}).

do_delete(Key) ->
    gen_server:cast(?MODULE, {delete, Key}).

do_take(Key) ->
    gen_server:call(?MODULE, {take, Key}).

handle_call({take, Key}, _From, #state{kv_store_pid = Ref} = State) ->
    Value = case leveled_bookie:book_get(whereis(Ref), "foo", Key) of
                {ok, V} -> V;
                not_found -> not_found
            end,
    {reply, Value, State}.

handle_cast({write, Key, Value}, #state{kv_store_pid = Ref} = State) ->
    leveled_bookie:book_put(whereis(Ref), "foo", Key, Value, []),
    {noreply, State};
handle_cast({delete, Key}, #state{kv_store_pid = Ref} = State) ->
    leveled_bookie:book_delete(whereis(Ref), "foo", Key, []),
    {noreply, State}.

handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) -> {ok, State}.
