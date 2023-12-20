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

-module(rabbit_delayed_stream_reader).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).


-export([setup/0]).

-record(state,
        {offset = 0, queue_type}).

setup() ->
    gen_server:call(?MODULE, setup).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

handle_call(setup, _From, #state{offset = Offset} = State) ->
    QName = rabbit_misc:r(<<"/">>, queue, <<"internal-dmx-queue">>),
    Spec = #{args => [{<<"x-stream-offset">>,long, Offset}],
             prefetch_count => 10,channel_pid => self(),
             consumer_tag => <<"foobar">>,exclusive_consume => false,
             no_ack => false,ok_msg => undefined},
    InitQType = rabbit_queue_type:init(),
    {ok, QType} = rabbit_amqqueue:with(
                    QName,
                    fun(Q) ->
                            rabbit_queue_type:consume(Q, Spec, InitQType)
                    end),
    {reply, ok, State#state{queue_type = QType}};
handle_call(_M, _From, State) ->
    rabbit_log:debug(">>> CALL ~p", [_M]),
    {reply, ok, State}.

handle_cast({queue_event, _,_} = Event, State) ->
    rabbit_log:debug(">>> CAST ~p", [Event]),
    case handle_queue_event(Event, State) of
        {ok, NState} ->
            {noreply, NState};
        {error, Reason, NState} ->
            {stop, Reason, NState}
    end.

handle_info(_I, State) ->
    rabbit_log:debug(">>> INFO ~p", [_I]),
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) -> {ok, State}.


handle_queue_event({queue_event, QName, Evt}, State0 = #state{queue_type = QType0}) ->
    case rabbit_queue_type:handle_event(QName, Evt, QType0) of
        {ok, QType, Actions} ->
            State1 = State0#state{queue_type = QType},
            State = handle_queue_actions(Actions, State1),
            {ok, State};
        {eol, Actions} ->
            State1 = handle_queue_actions(Actions, State0),
            QType = rabbit_queue_type:remove(QName, QType0),
            State = State1#state{queue_type = QType},
            {ok, State};
        {protocol_error, _Type, _Reason, _ReasonArgs} = Error ->
            {error, Error, State0}
    end.

handle_queue_actions(Actions, State) ->
    rabbit_log:debug(">>> handle actions ~p", [Actions]),
    State.

%% {ok, QueueType} = rabbit_queue_type:init().
%% QN = #resource{virtual_host = <<"/">>,kind = queue,
%%           name = <<"test">>}
%% Result2 = rabbit_amqqueue:with(QN, fun(Q1) -> rabbit_queue_type:consume(Q1, Spec5, S5) end).
%% rabbit_queue_type:handle_event(QName, E1, S666).
%% rabbit_queue_type:settle(QName, none, <<"foobar">>, NewDevs, S2003).
