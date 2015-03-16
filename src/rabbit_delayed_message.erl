%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

%% NOTE that this module uses erlang:now/0 instead of os:timestamp/0
%% See the relation of now/0 and timers here:
%% http://erlang.org/pipermail/erlang-questions/2015-March/083794.html

-module(rabbit_delayed_message).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange delayed message dets setup"},
                    {mfa, {?MODULE, setup_dets, []}},
                    {cleanup, {?MODULE, disable_plugin, []}},
                    {requires, external_infrastructure},
                    {enables, rabbit_registry}]}).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-behaviour(gen_server).

-export([start_link/0, delay_message/3, setup_dets/0, disable_plugin/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-import(rabbit_misc, [table_lookup/2]).

-ifdef(use_specs).

-type t_reference() :: reference().
-type delay() :: non_neg_integer().
-type exchange_module() :: atom().


-spec delay_message(rabbit_types:exchange(), exchange_module(),
                    rabbit_types:delivery()) ->
                           nodelay | {ok, t_reference().

-spec process_delivery(t_reference(),
                       rabbit_types:exchange(), exchange_module(),
                       rabbit_types:delivery()) ->
                              nodelay | {ok, t_reference()}.

-spec internal_delay_message(t_reference(),
                             rabbit_types:exchange(), exchange_module(),
                             rabbit_types:delivery(), delay()) ->
                                    nodelay | {ok, t_reference()}.

-endif.

-define(SERVER, ?MODULE).
-define(TABLE_NAME, ?MODULE).
-define(INTEGER_ARG_TYPES, [byte, short, signedint, long]).
-define(ERL_MAX_T, 4294967295). %% Max timer delay, per Erlang docs.

-record(state, {timer}).
-record(delay_key, {timestamp, exchange, type}).
-record(delay_entry, {key, delivery}).

%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

delay_message(Exchange, Type, Delivery) ->
    gen_server:call(?MODULE, {delay_message, Exchange, Type, Delivery}, infinity).

setup_dets() ->
    File = filename:join(rabbit_mnesia:dir(), "delayed_message.dets"),
    {ok, _} = dets:open_file(?TABLE_NAME, [{file, File},
                                           {keypos, #delay_entry.key},
                                           {ramfile, true},
                                           {type, duplicate_bag}]).

disable_plugin() ->
    dets:close(?TABLE_NAME).

%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{timer = make_ref()}}.

handle_call({delay_message, Exchange, Type, Delivery},
            _From, State = #state{timer = CurrTimer}) ->
    Reply = process_delivery(CurrTimer, Exchange, Type, Delivery),
    State2 = case Reply of
                 {ok, NewTimer} ->
                     State#state{timer = NewTimer};
                 _ ->
                     State
             end,
    {reply, Reply, State2};

handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(_C, State) ->
    {noreply, State}.

handle_info({deliver, Key}, State) ->
    case dets:lookup(?TABLE_NAME, Key) of
        [] ->
            ok;
        Deliveries ->
            route(Key, Deliveries),
            dets:delete(?TABLE_NAME, Key)
    end,

    _Ret =
        case dets:first(?TABLE_NAME) of
            %% destructuring to prevent matching '$end_of_table'
            #delay_key{timestamp = FirstTS} = Key2 ->
                %% there are messages that expired and need to be delivered
                Now = rabbit_misc:now_to_ms(now()),
                {ok, start_timer(FirstTS - Now, Key2)};
            _ ->
                %% nothing to do
                ok
        end,
    {noreply, State};
handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) ->
    dets:sync(?TABLE_NAME),
    dets:close(?TABLE_NAME),
    ok.

code_change(_, State, _) -> {ok, State}.

%%--------------------------------------------------------------------

route(#delay_key{exchange = Ex, type = Type}, Deliveries) ->
    lists:map(fun (#delay_entry{delivery = D}) ->
                      Dests = Type:route(Ex, D),
                      Qs = rabbit_amqqueue:lookup(Dests),
                      rabbit_amqqueue:deliver(Qs, D)
              end, Deliveries).

process_delivery(CurrTimer, Exchange, Type, Delivery) ->
    case msg_headers(Delivery) of
        undefined ->
            nodelay;
        H ->
            case table_lookup(H, <<"x-delay">>) of
                {Type, Delay} ->
                    case check_int_arg(Type) of
                        ok when Delay > 0, Delay =< ?ERL_MAX_T ->
                            internal_delay_message(CurrTimer,
                                                   Exchange, Type,
                                                   Delivery, Delay);
                        _  ->
                            nodelay
                    end
            end
    end.

internal_delay_message(CurrTimer, Exchange, Type, Delivery, Delay) ->
    Now = rabbit_misc:now_to_ms(now()),
    %% keys are timestamps in milliseconds,in the future
    DelayTS = Now + Delay,
    dets:insert(?TABLE_NAME, make_delay(DelayTS, Exchange, Type, Delivery)),
    case erlang:read_timer(CurrTimer) of
        false ->
            %% last timer expired, we set a new timer for
            %% the next message to be delivered
            case dets:first(?TABLE_NAME) of
                %% destructuring to prevent matching '$end_of_table'
                #delay_key{timestamp = FirstTS} = Key
                  when FirstTS < DelayTS ->
                    %% there are messages that expired and need to be delivered
                    {ok, start_timer(FirstTS - Now, Key)};
                _ ->
                    %% empty table or DelayTS <= FirstTS
                    {ok, start_timer(Delay, make_key(DelayTS, Exchange, Type))}
            end;
        CurrMS when Delay < CurrMS ->
            %% Current timer lasts longer that new message delay
            erlang:cancel_timer(CurrTimer),
            {ok, start_timer(Delay, make_key(DelayTS, Exchange, Type))};
        _  ->
            {ok, CurrTimer}
    end.

msg_headers(Delivery) ->
    lists:foldl(fun (F, Acc) -> F(Acc) end,
                Delivery,
                [fun get_msg/1, fun get_content/1,
                 fun get_props/1, fun get_headers/1]).

get_msg(#delivery{message = Msg}) ->
    Msg.

get_content(#basic_message{content = Content}) ->
    Content.

get_props(#content{properties = Props}) ->
    Props.

get_headers(#'P_basic'{headers = H}) ->
    H.

%% adapted from rabbit_amqqueue.erl
check_int_arg(Type) ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end.

%% Key will be used upon message receipt to fetch
%% the deliveries form the database
start_timer(Delay, Key) ->
    erlang:start_timer(max(0, Delay), self(), {deliver, Key}).

make_delay(DelayTS, Exchange, Type, Delivery) ->
    #delay_entry{key = make_key(DelayTS, Exchange, Type),
                 delivery = Delivery}.

make_key(DelayTS, Exchange, Type) ->
    #delay_key{timestamp = DelayTS,
               exchange  = Exchange,
               type      = Type}.
