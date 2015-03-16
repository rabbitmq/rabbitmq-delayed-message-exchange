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

-module(rabbit_exchange_type_delayed_message).

-rabbit_boot_step(
   {?MODULE,
    [{description, "exchange type x-delayed-message: registry"},
     {mfa,         {rabbit_registry, register,
                    [exchange, <<"x-delayed-message">>, ?MODULE]}},
     {cleanup, {rabbit_registry, unregister,
                [exchange, <<"x-delayed-message">>]}},
     {requires,    rabbit_registry},
     {enables,     kernel_ready}]}).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-behaviour(rabbit_exchange_type).

-import(rabbit_misc, [table_lookup/2]).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, validate_binding/2,
         create/2, delete/3, policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).

-define(EXCHANGE(Ex), (rabbit_exchange:type_to_module(exchange_type(Ex)))).

%%----------------------------------------------------------------------------

description() ->
    [{name, <<"x-delayed-message">>},
     {description, <<"Delayed Message Exchange.">>}].

route(X, Delivery) ->
    Type = ?EXCHANGE(X),
    case delay_message(X, Type, Delivery) of
        nodelay ->
            %% route the message using proxy module
            Type:route(X, Delivery);
        _ ->
            []
    end.

validate(#exchange{arguments = Args} = X) ->
    case table_lookup(Args, <<"x-delayed-type">>) of
        {_ArgType, Type} when is_binary(Type) ->
            _Type = rabbit_exchange:check_type(Type),
            ?EXCHANGE(X):validate(X);
        _ ->
            rabbit_misc:protocol_error(precondition_failed,
                                       "Invalid argument, "
                                       "'x-delayed-type' must be"
                                       "an existing exchnage type",
                                       [])
    end.

validate_binding(_X, #binding{destination = #resource{kind = exchnage}}) ->
    {error, {binding_invalid, "e2e bindings not supported", []}};
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

%%----------------------------------------------------------------------------

delay_message(Exchange, Type, Delivery) ->
    rabbit_delayed_message:delay_message(Exchange, Type, Delivery).

%% assumes the type is set in the args and that validate/1 did its job
exchange_type(#exchange{arguments = Args}) ->
    case table_lookup(Args, <<"x-delayed-type">>) of
        {_ArgType, Type} -> Type;
        _ -> error
    end.
