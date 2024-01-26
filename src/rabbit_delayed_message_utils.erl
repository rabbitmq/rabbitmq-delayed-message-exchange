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

-define(INTEGER_ARG_TYPES, [long, ubyte, short, ushort, int, uint]).

-define(STRING_ARG_TYPES, [utf8, binary]).

-define(FLOAT_ARG_TYPES, [double, float]).

-import(rabbit_misc, [table_lookup/2, set_table_value/4]).

get_delay(Delivery) ->
    case mc:x_header(<<"x-delay">>, Delivery) of
        undefined ->
            {error, nodelay};
        {Type, Delay} ->
            case check_int_arg(Type) of
                ok -> {ok, Delay};
                _  ->
                    case try_convert_to_int(Type, Delay) of
                        {ok, Converted} -> {ok, Converted};
                        _               -> {error, nodelay}
                    end
            end
    end.

%% set the x-delay header to -Delay, so it won't be re-delayed and the
%% header can still be passed down via e2e to other queues that might
%% lay after the next exchange so these queues/consumers can tell the
%% message comes via the delay plugin.
swap_delay_header(Delivery) ->
    case get_delay(Delivery) of
        {ok, Delay} ->
            mc:set_annotation(<<"x-delay">>, -Delay, Delivery);
        _ ->
            Delivery
    end.

try_convert_to_int(Type, Delay) ->
    case lists:member(Type, ?STRING_ARG_TYPES) of
        true  -> {ok, rabbit_data_coercion:to_integer(Delay)};
        false ->
            case lists:member(Type, ?FLOAT_ARG_TYPES) of
                true  -> {ok, trunc(Delay)};
                false -> {error, {unacceptable_type, Type}}
            end
    end.

%% adapted from rabbit_amqqueue.erl
check_int_arg(Type) ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end.
