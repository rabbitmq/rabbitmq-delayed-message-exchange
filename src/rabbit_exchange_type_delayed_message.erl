%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_exchange_type_delayed_message).

-rabbit_boot_step(
   {?MODULE,
    [{description, "exchange type x-delayed-message: registry"},
     {mfa,         {rabbit_registry, register,
                    [exchange, <<"x-delayed-message">>, ?MODULE]}},
     {cleanup, {rabbit_registry, unregister,
                [exchange, <<"x-delayed-message">>]}},
     {requires,    rabbit_registry},
     {enables,     recovery}]}).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-behaviour(rabbit_exchange_type).

-import(rabbit_misc, [table_lookup/2]).
-import(rabbit_delayed_message_utils, [get_delay/1]).

-export([description/0, serialise_events/0, route/3]).
-export([validate/1, validate_binding/2,
         create/2, delete/2, policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

-define(EXCHANGE(Ex), (exchange_module(Ex))).
-define(ERL_MAX_T, 4294967295). %% Max timer delay, per Erlang docs.

%%----------------------------------------------------------------------------

description() ->
    [{name, <<"x-delayed-message">>},
     {description, <<"Delayed Message Exchange.">>}].

route(X = #exchange{name = Name},
      Message,
      Opts) ->
    case delay_message(X, Message) of
        nodelay ->
            %% route the message using proxy module
            case ?EXCHANGE(X) of
                rabbit_exchange_type_direct ->
                    RKs = mc:get_annotation(routing_keys, Message),
                    %% Exchange type x-delayed-message routes via "direct exchange routing v1"
                    %% even when feature flag direct_exchange_routing_v2 is enabled because
                    %% table rabbit_index_route only stores bindings whose source exchange
                    %% is of type direct exchange.
                    rabbit_router:match_routing_key(Name, RKs);
                Mod ->
                    Mod:route(X, Message, Opts)
            end;
        _ ->
            []
    end.

validate(#exchange{arguments = Args} = X) ->
    case table_lookup(Args, <<"x-delayed-type">>) of
        {_ArgType, <<"x-delayed-message">>} ->
            rabbit_misc:protocol_error(precondition_failed,
                                       "Invalid argument, "
                                       "'x-delayed-message' can't be used "
                                       "for 'x-delayed-type'",
                                       []);
        {_ArgType, Type} when is_binary(Type) ->
            rabbit_exchange:check_type(Type),
            ?EXCHANGE(X):validate(X);
        _ ->
            rabbit_misc:protocol_error(precondition_failed,
                                       "Invalid argument, "
                                       "'x-delayed-type' must be "
                                       "an existing exchange type",
                                       [])
    end.

validate_binding(X, B) ->
    ?EXCHANGE(X):validate_binding(X, B).
create(Serial, X) ->
    ?EXCHANGE(X):create(Serial, X).
delete(Serial, X) ->
    ?EXCHANGE(X):delete(Serial, X).
policy_changed(X1, X2) ->
    ?EXCHANGE(X1):policy_changed(X1, X2).
add_binding(Serial, X, B) ->
    ?EXCHANGE(X):add_binding(Serial, X, B).
remove_bindings(Serial, X, Bs) ->
    ?EXCHANGE(X):remove_bindings(Serial, X, Bs).
assert_args_equivalence(X, Args) ->
    ?EXCHANGE(X):assert_args_equivalence(X, Args).
serialise_events() -> false.

info(Exchange) ->
    info(Exchange, [messages_delayed]).

info(Exchange, Items) ->
    case lists:member(messages_delayed, Items) of
        false -> [];
        true  ->
            [{messages_delayed,
              rabbit_delayed_message:messages_delayed(Exchange)}]
    end.


%%----------------------------------------------------------------------------

delay_message(Exchange, Message) ->
    case get_delay(Message) of
        {ok, Delay} when Delay > 0, Delay =< ?ERL_MAX_T ->
            rabbit_delayed_message:delay_message(Exchange, Message, Delay);
        _ ->
            nodelay
    end.

%% assumes the type is set in the args and that validate/1 did its job
exchange_module(Ex) ->
    T = rabbit_registry:binary_to_type(exchange_type(Ex)),
    {ok, M} = rabbit_registry:lookup_module(exchange, T),
    M.

exchange_type(#exchange{arguments = Args}) ->
    case table_lookup(Args, <<"x-delayed-type">>) of
        {_ArgType, Type} -> Type;
        _ -> error
    end.
