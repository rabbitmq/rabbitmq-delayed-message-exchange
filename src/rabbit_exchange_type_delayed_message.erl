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

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, validate_binding/2,
         create/2, delete/3, policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

-define(EXCHANGE(Ex), (exchange_module(Ex))).
-define(ERL_MAX_T, 4294967295). %% Max timer delay, per Erlang docs.

%%----------------------------------------------------------------------------

description() ->
    [{name, <<"x-delayed-message">>},
     {description, <<"Delayed Message Exchange.">>}].

route(X, Delivery) ->
    case delay_message(X, Delivery) of
        nodelay ->
            %% route the message using proxy module
            ?EXCHANGE(X):route(X, Delivery);
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
create(Tx, X) ->
    ?EXCHANGE(X):create(Tx, X).
delete(Tx, X, Bs) ->
    ?EXCHANGE(X):delete(Tx, X, Bs).
policy_changed(X1, X2) ->
    ?EXCHANGE(X1):policy_changed(X1, X2).
add_binding(Tx, X, B) ->
    ?EXCHANGE(X):add_binding(Tx, X, B).
remove_bindings(Tx, X, Bs) ->
    ?EXCHANGE(X):remove_bindings(Tx, X, Bs).
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

delay_message(Exchange, Delivery) ->
    case get_delay(Delivery) of
        {ok, Delay} when Delay > 0, Delay =< ?ERL_MAX_T ->
            rabbit_delayed_message:delay_message(Exchange, Delivery, Delay);
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
