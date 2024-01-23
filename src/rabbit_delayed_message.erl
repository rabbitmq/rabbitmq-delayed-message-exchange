% This Source Code Form is subject to the terms of the Mozilla Public
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
-include_lib("khepri/include/khepri.hrl").

-rabbit_boot_step({?MODULE,
                   [{description, "exchange delayed message mnesia setup"},
                    {mfa, {?MODULE, setup, []}},
                    {cleanup, {?MODULE, disable_plugin, []}},
                    {requires,    recovery}]}).
                    %% {requires, external_infrastructure},
                    %% {enables, rabbit_registry}]}).

-behaviour(gen_server).

-export([start_link/0, delay_message/3, setup/0, disable_plugin/0, go/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
-export([messages_delayed/1, route/3]).

%% For testing, debugging and manual use
-export([refresh_config/0]).

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

-define(Timeout, 5000).

-record(state, {timer,
                khepri_mod,
                stats_state}).

%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

go() ->
    gen_server:cast(?MODULE, go).

delay_message(Exchange, Message, Delay) ->
    gen_server:call(?MODULE, {delay_message, Exchange, Message, Delay},
                    infinity).

setup() ->
    rabbit_delayed_message_kv_store:setup(),
    ok.

disable_plugin() ->
    ok.

messages_delayed(_Exchange) ->
    %% ExchangeName = Exchange#exchange.name,
    %% MatchHead = #delay_entry{delay_key = make_key('_', #exchange{name = ExchangeName, _ = '_'}),
    %%                          delivery  = '_', ref       = '_'},
    %% Delays = mnesia:dirty_select(?TABLE_NAME, [{MatchHead, [], [true]}]),
    Delays = [],
    length(Delays).

refresh_config() ->
    gen_server:call(?MODULE, refresh_config).

%%--------------------------------------------------------------------

init([]) ->
    _ = recover(),
    {ok, #state{}}.

handle_call({delay_message, Exchange, Message, Delay},
            _From, State) ->
    %% TODO perhaps write and read should be handled in different processes.
    ok = internal_delay_message(State, Exchange, Message, Delay),
    {reply, ok, State};
handle_call(refresh_config, _From, State) ->
    {reply, ok, refresh_config(State)};
handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(go, State) ->
    State2 = refresh_config(State),
    Ref = erlang:send_after(?Timeout, self(), check_msgs),
    rabbit_delayed_stream_reader:setup(),
    {noreply, State2#state{timer = Ref}};
handle_cast(_C, State) ->
    {noreply, State}.

handle_info(check_msgs, #state{khepri_mod = Mod} = State) ->
    case ra_leaderboard:lookup_leader(Mod:get_store_id()) of
        {_Name, Node} when Node == node() ->
            %% Better way to start this on the nodes?.
            rabbit_delayed_message_kv_store:maybe_make_cluster(),
            {ok, Es}  =
                Mod:match(
                  [delayed_message_exchange,
                   #if_path_matches{regex=any},
                   #if_all{conditions =
                               [delivery_time,
                                #if_data_matches{pattern = '$1',
                                                 conditions = [{'<', '$1', erlang:system_time(milli_seconds)}]}
                               ]
                          }
                  ]),
            Keys = [[delayed_message_exchange, Key] || {[delayed_message_exchange, Key|_], _} <- maps:to_list(Es)],
            route_messages(Keys, State);
        _ ->
            ok
    end,
    Ref = erlang:send_after(?Timeout, self(), check_msgs),
    {noreply, State#state{timer = Ref}};
handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) -> {ok, State}.

%%--------------------------------------------------------------------

route_messages([], State) ->
    State;
route_messages([Key|Keys], #state{khepri_mod = Mod} = State) ->
    {ok, Exchange} = Mod:get(Key++[exchange]),
    [_, MsgKey] = Key,
    V = rabbit_delayed_message_kv_store:do_take(MsgKey),
    route(Exchange, [V], State),
    rabbit_delayed_message_kv_store:delete(MsgKey),
    Mod:delete(Key),
    route_messages(Keys, State).

route(Ex, Deliveries, State) ->
    ExName = Ex#exchange.name,
    rabbit_log:debug(">>> Delayed message exchange:~nEX:~n~pDevs:~n~p",[Ex, Deliveries]),
    lists:map(fun (Msg0) ->
                      Msg1 = case Msg0 of
                                 #delivery{message = BasicMessage} ->
                                     BasicMessage;
                                 _MC ->
                                     Msg0
                             end,
                      Msg2 = rabbit_delayed_message_utils:swap_delay_header(Msg1),
                      Dests = rabbit_exchange:route(Ex, Msg2),
                      Qs = rabbit_amqqueue:lookup_many(Dests),
                      _ = rabbit_queue_type:deliver(Qs, Msg2, #{}, stateless),
                      bump_routed_stats(ExName, Qs, State)
              end, Deliveries).

internal_delay_message(#state{khepri_mod = Mod}, Exchange, Message, Delay) ->
    Now = erlang:system_time(milli_seconds),
    DelayTS = Now + Delay,
    Key = make_key(DelayTS, Exchange),
    Mod:put([delayed_message_exchange, Key, delivery_time], DelayTS),
    Mod:put([delayed_message_exchange, Key, exchange], Exchange),
    Dests = [#resource{virtual_host = <<"/">>,kind = queue,
                       name = <<"internal-dmx-queue">>}],
    Qs = rabbit_amqqueue:lookup_many(Dests),
    MsgWithKey = mc:set_annotation(<<"x-delay-key">>, Key, Message),
    _ = rabbit_queue_type:deliver(Qs, MsgWithKey, #{}, stateless),
    ok = rabbit_delayed_message_kv_store:write(Key, Message).


make_key(_DelayTS, _Exchange) ->
    %% TODO: make unique, or store more than one msg/exchange data with the key.
    %% BinDelayTS = integer_to_binary(DelayTS),
    %% ExchangeName = Exchange#exchange.name#resource.name,
    %% <<ExchangeName/binary, BinDelayTS/binary>>.

    %% TODO: Just a uuid for now. Any need to make the key actually matter?
    rabbit_guid:gen().

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

refresh_config(State0) ->
    Mod = case rabbit_feature_flags:is_enabled(khepri_db) of
              true ->
                  rabbit_khepri;
              false ->
                  ok = rabbit_delayed_message_khepri:setup(),
                  rabbit_delayed_message_khepri
          end,

    State = rabbit_event:init_stats_timer(State0, #state.stats_state),
    State#state{khepri_mod = Mod}.
