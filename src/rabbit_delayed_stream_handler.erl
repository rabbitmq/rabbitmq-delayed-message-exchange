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

-module(rabbit_delayed_stream_handler).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).


-export([setup/0, store_msg_with_key/2, delete_msg_with_key/1]).

-record(state,
        {offset = 0, queue_type}).

-define(STREAM_QUEUE_NAME, <<"internal-dmx-queue">>).
-define(STREAM_QUEUE,
        rabbit_misc:r(<<"/">>, queue, ?STREAM_QUEUE_NAME)).
-define(CTAG, <<"dmx-stream-handler">>).

setup() ->
    gen_server:cast(?MODULE, setup).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

handle_call(_M, _From, State) ->
    rabbit_log:debug(">>> CALL ~p", [_M]),
    {reply, ok, State}.

handle_cast(setup, #state{offset = Offset} = State) ->
    QName = ?STREAM_QUEUE,
    case rabbit_amqqueue:exists(QName) of
        true ->
            {ok, TmpQ} =  rabbit_db_queue:get(QName),
            #{name := StreamId} = amqqueue:get_type_state(TmpQ),
            %% TODO must be some smarter way to figure out if the stream is up and running on this host
            case rabbit_stream_coordinator:stream_overview(StreamId) of
                {error, noproc} ->
                    erlang:send_after(5000, self(), call_setup_again),
                    {noreply, State};
                _ ->
                    Spec = #{args => [{<<"x-stream-offset">>,long, Offset}],
                             prefetch_count => 10,channel_pid => self(),
                             consumer_tag => ?CTAG, exclusive_consume => false,
                             no_ack => false,ok_msg => undefined},
                    InitQType = rabbit_queue_type:init(),
                    {ok, QType} = rabbit_amqqueue:with(
                                    QName,
                                    fun(Q) ->
                                            rabbit_queue_type:consume(Q, Spec, InitQType)
                                    end),
                    Offset = get_offset(),
                    {noreply, State#state{queue_type = QType, offset = Offset}}
            end;
        false ->
            erlang:send_after(5000, self(), call_setup_again),
            {noreply, State}
    end;
handle_cast({queue_event, _,_} = Event, State) ->
    rabbit_log:debug(">>> CAST ~p", [Event]),
    case handle_queue_event(Event, State) of
        {ok, NState} ->
            {noreply, NState};
        {error, Reason, NState} ->
            {stop, Reason, NState}
    end.

handle_info(call_setup_again, State) ->
    handle_cast(setup, State);
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
            %% TODO Update offset, both in state, but also in kv store?
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
    lists:foldl(
      fun ({deliver, ?CTAG, Ack, Msgs}, S) ->
              read_msgs(Msgs, Ack, S);
          ({settled, _QName, _PktIds}, S) ->
              S;
          ({rejected, _QName, _PktIds}, S) ->
              S;
          ({block, _QName}, S) ->
              S;
          ({unblock, _QName}, S) ->
              S;
          ({queue_down, _QName}, S) ->
              S
      end, State, Actions).

read_msgs(Msgs, Ack, State) ->
    lists:foldl(fun(Msg, S = #state{queue_type = _QType}) ->
                        read_msg(Msg, Ack, S)
                end, State, Msgs).


read_msg({QNameOrType, _QPid, QMsgId, _Redelivered, Mc} = _Delivery,
         _Ack, S = #state{queue_type = QType}) ->
    case mc:x_header(<<"x-tombstone-key">>, Mc) of
        undefined ->
            {binary, Key} =  mc:x_header(<<"x-delay-key">>, Mc),
            rabbit_delayed_message_kv_store:do_write(Key, Mc);
        {_, TKey} ->
            rabbit_delayed_message_kv_store:do_delete(TKey)
    end,
    NewOffset = mc:get_annotation(<<"x-stream-offset">>, Mc) + 1,
    set_offset(NewOffset),
    {ok, QType0, Actions} =
        rabbit_queue_type:settle(QNameOrType, none, ?CTAG, [QMsgId], QType),
    handle_queue_actions(Actions, S#state{queue_type = QType0,
                                          offset = NewOffset}).


%% {ok, QueueType} = rabbit_queue_type:init().
%% QN = #resource{virtual_host = <<"/">>,kind = queue,
%%           name = <<"test">>}
%% Result2 = rabbit_amqqueue:with(QN, fun(Q1) -> rabbit_queue_type:consume(Q1, Spec5, S5) end).
%% rabbit_queue_type:handle_event(QName, E1, S666).
%% rabbit_queue_type:settle(QName, none, <<"foobar">>, NewDevs, S2003).
declare_queue() ->
    %%TODO maybe max age and max length bytes from config.
    rabbit_amqqueue:declare(?STREAM_QUEUE,
                            true,
                            false,
                            [{<<"x-queue-type">>, longstr, <<"stream">>},{<<"x-max-age">>, longstr, <<"5D">>}],
                            none, <<"dmx">>, node()).

add_to_stream(Message) ->
    Dests = [?STREAM_QUEUE],
    Qs = rabbit_amqqueue:lookup_many(Dests),
    _ = rabbit_queue_type:deliver(Qs, Message, #{}, stateless).

store_msg_with_key(Message, Key) ->
    case rabbit_amqqueue:exists(?STREAM_QUEUE) of
        true ->
            ok;
        false ->
            declare_queue()
    end,
    MsgWithKey = mc:set_annotation(<<"x-delay-key">>, Key, Message),
    add_to_stream(MsgWithKey).

delete_msg_with_key(MsgKey) ->
    Ann = #{x => <<"">>, rk => [?STREAM_QUEUE_NAME],
            <<"x-tombstone-key">> => MsgKey},
    Msg =  mc:init(mc_amqp, [], Ann),
    add_to_stream(Msg).

set_offset(Offset) ->
    rabbit_delayed_message_kv_store:do_write(offset, Offset).

get_offset() ->
    case rabbit_delayed_message_kv_store:do_take(offset) of
        not_found ->
            0;
        V ->
            V
    end.
