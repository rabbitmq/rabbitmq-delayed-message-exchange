%%  The contents of this file are subject to the Mozilla Public License
%%  Version 2.0 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ Delayed Message
%%
%%  The Initial Developer of the Original Code is Pivotal Software, Inc.
%%  Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

%% NOTE that this module uses os:timestamp/0 but in the future Erlang
%% will have a new time API.
%% See:
%% http://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/erlang.html#now-0
%% and
%% http://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/time_correction.html

-module(rabbit_delayed_message).

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

-import(rabbit_delayed_message_utils, [swap_delay_header/1]).

-ifdef(use_specs).

-type t_reference() :: reference().
-type delay() :: non_neg_integer().


-spec delay_message(rabbit_types:exchange(),
                    rabbit_types:delivery()) ->
                           nodelay | {ok, t_reference()}.

-spec internal_delay_message(t_reference(),
                             rabbit_types:exchange(),
                             rabbit_types:delivery(),
                             delay()) ->
                                    nodelay | {ok, t_reference()}.

-endif.

-define(SERVER, ?MODULE).
-define(TABLE_NAME, append_to_atom(?MODULE, node())).
-define(INDEX_TABLE_NAME, append_to_atom(?TABLE_NAME, "_index")).

-record(state, {timer}).

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

delay_message(Exchange, Delivery, Delay) ->
    gen_server:call(?MODULE, {delay_message, Exchange, Delivery, Delay},
                    infinity).

setup_mnesia() ->
    mnesia:create_table(?TABLE_NAME, [{record_name, delay_entry},
                                      {attributes,
                                       record_info(fields, delay_entry)},
                                      {type, bag},
                                      {disc_copies, [node()]}]),
    mnesia:create_table(?INDEX_TABLE_NAME, [{record_name, delay_index},
                                            {attributes,
                                             record_info(fields, delay_index)},
                                            {type, ordered_set},
                                            {disc_copies, [node()]}]),
    mnesia:wait_for_tables([?TABLE_NAME, ?INDEX_TABLE_NAME], 30000).

disable_plugin() ->
    mnesia:delete_table(?INDEX_TABLE_NAME),
    mnesia:delete_table(?TABLE_NAME),
    ok.

%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{timer = not_set}}.

handle_call({delay_message, Exchange, Delivery, Delay},
            _From, State = #state{timer = CurrTimer}) ->
    Reply = internal_delay_message(CurrTimer, Exchange, Delivery, Delay),
    State2 = case Reply of
                 {ok, NewTimer} ->
                     State#state{timer = NewTimer};
                 _ ->
                     State
             end,
    {reply, Reply, State2};

handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(go, State) ->
    {noreply, State#state{timer = maybe_delay_first()}};
handle_cast(_C, State) ->
    {noreply, State}.

handle_info({timeout, _TimerRef, {deliver, Key}}, State) ->
    case mnesia:dirty_read(?TABLE_NAME, Key) of
        [] ->
            ok;
        Deliveries ->
            route(Key, Deliveries),
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
            %% there are messages that expired and need to be delivered
            Now = time_compat:erlang_system_time(milli_seconds),
            start_timer(FirstTS - Now, Key2);
        _ ->
            %% nothing to do
            not_set
    end.

route(#delay_key{exchange = Ex}, Deliveries) ->
    lists:map(fun (#delay_entry{delivery = D}) ->
                      D2 = swap_delay_header(D),
                      Dests = rabbit_exchange:route(Ex, D2),
                      Qs = rabbit_amqqueue:lookup(Dests),
                      rabbit_amqqueue:deliver(Qs, D2)
              end, Deliveries).

internal_delay_message(CurrTimer, Exchange, Delivery, Delay) ->
    Now = time_compat:erlang_system_time(milli_seconds),
    %% keys are timestamps in milliseconds,in the future
    DelayTS = Now + Delay,
    mnesia:dirty_write(?INDEX_TABLE_NAME,
                       make_index(DelayTS, Exchange)),
    mnesia:dirty_write(?TABLE_NAME,
                       make_delay(DelayTS, Exchange, Delivery)),
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
                    erlang:cancel_timer(CurrTimer),
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
