%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_delayed_message_utils).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-export([get_delay/1, swap_delay_header/1]).

-define(INTEGER_ARG_TYPES, [byte, short, signedint, long, unsignedbyte, unsignedshort, unsignedint]).

-define(STRING_ARG_TYPES, [longstr, shortstr]).

-define(FLOAT_ARG_TYPES, [decimal, double, float]).

-import(rabbit_misc, [table_lookup/2, set_table_value/4]).

get_delay(Delivery) ->
    case msg_headers(Delivery) of
        undefined ->
            {error, nodelay};
        H ->
            get_delay_header(H)
    end.

get_delay_header(H) ->
    case table_lookup(H, <<"x-delay">>) of
        {Type, Delay} ->
            case check_int_arg(Type) of
                ok -> {ok, Delay};
                _  -> 
                    case try_convert_to_int(Type, Delay) of
                        {ok, Converted} -> {ok, Converted};
                        _               -> {error, nodelay}
                    end
            end;
        _ ->
            {error, nodelay}
    end.

%% set the x-delay header to -Delay, so it won't be re-delayed and the
%% header can still be passed down via e2e to other queues that might
%% lay after the next exchange so these queues/consumers can tell the
%% message comes via the delay plugin.
swap_delay_header(Delivery) ->
    case msg_headers(Delivery) of
        undefined ->
            Delivery;
        H ->
            case get_delay_header(H) of
                {ok, Delay} ->
                    H2 = set_table_value(H, <<"x-delay">>, signedint, -Delay),
                    set_delivery_headers(Delivery, H2);
                _  ->
                    Delivery
            end
    end.

set_delivery_headers(Delivery, H) ->
    Msg = get_msg(Delivery),
    Content = get_content(Msg),
    Props = get_props(Content),

    Props2 = Props#'P_basic'{headers = H},
    Content2 = Content#content{properties = Props2},
    Msg2 = Msg#basic_message{content = Content2},

    Delivery#delivery{message = Msg2}.

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

try_convert_to_int(Type, Delay) ->
    case lists:member(Type, ?STRING_ARG_TYPES) of
        true  -> {ok, binary_to_integer(Delay)};
        false -> 
            case lists:member(Type, ?FLOAT_ARG_TYPES) of
                true  -> {ok, trunc(Delay)};
                false -> {error, {unacceptable_type, Type}}
            end.
    end.

%% adapted from rabbit_amqqueue.erl
check_int_arg(Type) ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end.
