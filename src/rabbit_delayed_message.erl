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

-module(rabbit_delayed_message).
-include_lib("rabbit_common/include/rabbit.hrl").
-rabbit_boot_step({?MODULE,
                   [{description, "exchange delayed message mnesia setup"},
                    {mfa, {?MODULE, setup_mnesia, []}},
                    {cleanup, {?MODULE, disable_plugin, []}},
                    {requires, external_infrastructure},
                    {enables, rabbit_registry}]}).

-behaviour(gen_server).

-export([start_link/0, delay_message/3, setup_mnesia/0, disable_plugin/0, go/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([messages_delayed/1]).

%% For testing, debugging and manual use
-export([refresh_config/0,
         table_name/0,
         index_table_name/0]).

-import(rabbit_delayed_message_utils, [swap_delay_header/1]).

-type t_reference() :: reference().
-type delay() :: non_neg_integer().


-spec delay_message(rabbit_types:exchange(),
                    mc:state(),
                    delay()) ->
                           nodelay | {ok, t_reference()}.

-spec internal_delay_message(t_reference(),
                             rabbit_types:exchange(),
                             mc:state(),
                             delay()) ->
                                    nodelay | {ok, t_reference()}.

-define(TABLE_NAME, append_to_atom(?MODULE, node())).
-define(INDEX_TABLE_NAME, append_to_atom(?TABLE_NAME, "_index")).

-record(state, {timer,
                stats_state}).

-record(delay_key,
        { timestamp, %% timestamp delay
          exchange   %% rabbit_types:exchange()
        }).

-record(delay_entry,
        { delay_key, %% delay_key record
          delivery,  %% the message delivery
          ref        %% ref to make records distinct for 'bag' semantics.
        }).

-record(delay_index,
        { delay_key, %% delay_key record
          const      %% record must have two fields
        }).

%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

go() ->
    gen_server:cast(?MODULE, go).

delay_message(Exchange, Message, Delay) ->
    gen_server:call(?MODULE, {delay_message, Exchange, Message, Delay},
                    infinity).

setup_mnesia() ->
    _ = mnesia:create_table(?TABLE_NAME, [{record_name, delay_entry},
                                          {attributes,
                                           record_info(fields, delay_entry)},
                                          {type, bag},
                                          {disc_copies, [node()]}]),
    _ = mnesia:create_table(?INDEX_TABLE_NAME, [{record_name, delay_index},
                                                {attributes,
                                                 record_info(fields, delay_index)},
                                                {type, ordered_set},
                                                {disc_copies, [node()]}]),
    rabbit_table:wait([?TABLE_NAME, ?INDEX_TABLE_NAME]).

disable_plugin() ->
    _ = mnesia:delete_table(?INDEX_TABLE_NAME),
    _ = mnesia:delete_table(?TABLE_NAME),
    ok.

messages_delayed(Exchange) ->
    ExchangeName = Exchange#exchange.name,
    MatchHead = #delay_entry{delay_key = make_key('_', #exchange{name = ExchangeName, _ = '_'}),
                             delivery  = '_', ref       = '_'},
    Delays = mnesia:dirty_select(?TABLE_NAME, [{MatchHead, [], [true]}]),
    length(Delays).

refresh_config() ->
    gen_server:call(?MODULE, refresh_config).

%%--------------------------------------------------------------------

init([]) ->
    _ = recover(),
    {ok, #state{timer = not_set}}.

handle_call({delay_message, Exchange, Message, Delay},
            _From, State = #state{timer = CurrTimer}) ->
    Reply = {ok, NewTimer} = internal_delay_message(CurrTimer, Exchange, Message, Delay),
    State2 = State#state{timer = NewTimer},
    {reply, Reply, State2};
handle_call(refresh_config, _From, State) ->
    {reply, ok, refresh_config(State)};
handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(go, State) ->
    State2 = refresh_config(State),
    {noreply, State2#state{timer = maybe_delay_first()}};
handle_cast(_C, State) ->
    {noreply, State}.

handle_info({timeout, _TimerRef, {deliver, Key}}, State) ->
    case mnesia:dirty_read(?TABLE_NAME, Key) of
        [] ->
            mnesia:dirty_delete(?INDEX_TABLE_NAME, Key);
        Deliveries ->
            _ = route(Key, Deliveries, State),
            mnesia:dirty_delete(?TABLE_NAME, Key),
            mnesia:dirty_delete(?INDEX_TABLE_NAME, Key)
    end,
    {noreply, State#state{timer = maybe_delay_first()}};
handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) -> {ok, State}.

%%--------------------------------------------------------------------

maybe_delay_first() ->
    case mnesia:dirty_first(?INDEX_TABLE_NAME) of
        %% destructuring to prevent matching '$end_of_table'
        #delay_key{timestamp = FirstTS} = Key2 ->
            %% there are messages that will expire and need to be delivered
            Now = erlang:system_time(milli_seconds),
            start_timer(FirstTS - Now, Key2);
        _ ->
            %% nothing to do
            not_set
    end.

route(#delay_key{exchange = Ex}, Deliveries, State) ->
    ExName = Ex#exchange.name,
    lists:map(fun (#delay_entry{delivery = Msg0}) ->
                      Msg1 = case Msg0 of
                               #delivery{message = BasicMessage} ->
                                     BasicMessage;
                               _MC ->
                                   Msg0
                           end,
                      Msg2 = swap_delay_header(Msg1),
                      Dests = rabbit_exchange:route(Ex, Msg2),
                      Qs = rabbit_amqqueue:lookup_many(Dests),
                      _ = rabbit_queue_type:deliver(Qs, Msg2, #{}, stateless),
                      bump_routed_stats(ExName, Qs, State)
              end, Deliveries).

internal_delay_message(CurrTimer, Exchange, Message, Delay) ->
    Now = erlang:system_time(milli_seconds),
    %% keys are timestamps in milliseconds,in the future
    DelayTS = Now + Delay,
    mnesia:dirty_write(?INDEX_TABLE_NAME,
                       make_index(DelayTS, Exchange)),
    mnesia:dirty_write(?TABLE_NAME,
                       make_delay(DelayTS, Exchange, Message)),
    case CurrTimer of
        not_set ->
            %% No timer in progress, so we start our own.
            {ok, maybe_delay_first()};
        _ ->
            case erlang:read_timer(CurrTimer) of
                false ->
                    %% Timer is already expired.  Handler will be invoked soon.
                    {ok, CurrTimer};
                CurrMS when Delay < CurrMS ->
                    %% Current timer lasts longer that new message delay
                    _ = erlang:cancel_timer(CurrTimer),
                    {ok, start_timer(Delay, make_key(DelayTS, Exchange))};
                _ ->
                    %% Timer is set to expire sooner than this
                    %% message's scheduled delivery time.
                    {ok, CurrTimer}
            end
    end.

%% Key will be used upon message receipt to fetch
%% the deliveries from the database
start_timer(Delay, Key) ->
    erlang:start_timer(erlang:max(0, Delay), self(), {deliver, Key}).

make_delay(DelayTS, Exchange, Delivery) ->
    #delay_entry{delay_key = make_key(DelayTS, Exchange),
                 delivery  = Delivery,
                 ref       = make_ref()}.

make_index(DelayTS, Exchange) ->
    #delay_index{delay_key = make_key(DelayTS, Exchange),
                 const = true}.

make_key(DelayTS, Exchange) ->
    #delay_key{timestamp = DelayTS,
               exchange  = Exchange}.

append_to_atom(Atom, Append) when is_atom(Append) ->
    append_to_atom(Atom, atom_to_list(Append));
append_to_atom(Atom, Append) when is_list(Append) ->
    list_to_atom(atom_to_list(Atom) ++ Append).

recover() ->
    %% topology recovery has already happened, we have to recover state for any durable
    %% consistent hash exchanges since plugin activation was moved later in boot process
    %% starting with RabbitMQ 3.8.4
    case list_exchanges() of
        {ok, Xs} ->
            rabbit_log:debug("Delayed message exchange: "
                              "have ~b durable exchanges to recover",
                             [length(Xs)]),
            [recover_exchange_and_bindings(X) || X <- lists:usort(Xs)];
        {aborted, Reason} ->
            rabbit_log:error(
                "Delayed message exchange: "
                 "failed to recover durable bindings of one of the exchanges, reason: ~p",
                [Reason])
    end.

list_exchanges() ->
    case mnesia:transaction(
           fun () ->
                   mnesia:match_object(
                     rabbit_exchange, #exchange{durable = true,
                                                type = 'x-delayed-message',
                                                _ = '_'}, write)
           end) of
        {atomic, Xs} ->
            {ok, Xs};
        {aborted, Reason} ->
            {aborted, Reason}
    end.

recover_exchange_and_bindings(#exchange{name = XName} = X) ->
    mnesia:transaction(
        fun () ->
            Bindings = rabbit_binding:list_for_source(XName),
            _ = [rabbit_exchange_type_delayed_message:add_binding(transaction, X, B)
                 || B <- lists:usort(Bindings)],
            rabbit_log:debug("Delayed message exchange: "
                              "recovered bindings for ~s",
                             [rabbit_misc:rs(XName)])
    end).

%% These metrics are normally bumped from a channel process via which
%% the publish actually happened. In the special case of delayed
%% message delivery, the singleton delayed_message gen_server does
%% this.
%%
%% Difference from delivering from a channel:
%%
%% The channel process keeps track of the state and monitors each
%% queue it routed to. When the channel is notified of a queue DOWN,
%% it marks all core metrics for that channel + queue as deleted.
%% Monitoring all queues would be overkill for the delayed message
%% gen_server, so this delete marking does not happen in this
%% case. Still `rabbit_core_metrics_gc' will periodically scan all the
%% core metrics and eventually delete entries for non-existing queues
%% so there won't be any metrics leak. `rabbit_core_metrics_gc' will
%% also delete the entries when this process is not alive ie when the
%% plugin is disabled.
bump_routed_stats(ExName, Qs, State) ->
    rabbit_global_counters:messages_routed(amqp091, length(Qs)),
    case rabbit_event:stats_level(State, #state.stats_state) of
        fine ->
            [begin
                 QName = amqqueue:get_name(Q),
                 %% Channel PID is just an identifier in the metrics
                 %% DB. However core metrics GC will delete entries
                 %% with a not-alive PID, and by the time the delayed
                 %% message gets delivered the original channel
                 %% process might be long gone, hence we need a live
                 %% PID in the key.
                 FakeChannelId = self(),
                 Key = {FakeChannelId, {QName, ExName}},
                 rabbit_core_metrics:channel_stats(queue_exchange_stats, publish, Key, 1)
             end
             || Q <- Qs],
            ok;
        _ ->
            ok
    end.

refresh_config(State) ->
    rabbit_event:init_stats_timer(State, #state.stats_state).

table_name() ->
    ?TABLE_NAME.

index_table_name() ->
    ?INDEX_TABLE_NAME.
