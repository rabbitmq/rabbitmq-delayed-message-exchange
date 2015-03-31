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
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2015 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_delayed_message_utils).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-export([get_delay/1, swap_delay_header/1]).

-define(INTEGER_ARG_TYPES, [byte, short, signedint, long]).

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
                _  -> {error, nodelay}
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

%% adapted from rabbit_amqqueue.erl
check_int_arg(Type) ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end.
