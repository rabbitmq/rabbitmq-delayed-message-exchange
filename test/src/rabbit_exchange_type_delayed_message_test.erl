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

-module(rabbit_exchange_type_delayed_message_test).

-export([test/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(RABBIT, {"test", 5672}).
-define(HARE,   {"hare", 5673}).

-import(rabbit_exchange_type_delayed_message_test_util,
        [start_other_node/1, reset_other_node/1, stop_other_node/1]).

test() ->
    ok = eunit:test(tests(?MODULE, 60), [verbose]).

wrong_exchange_argument_type_test() ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),
    Ex = <<"fail">>,
    Type = <<"x-not-valid-type">>,
    process_flag(trap_exit, true),
    ?assertExit(_, amqp_channel:call(Chan, make_exchange(Ex, Type))),
    amqp_connection:close(Conn),
    ok.

exchange_argument_type_not_self_test() ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),
    Ex = <<"fail">>,
    Type = <<"x-delayed-message">>,
    process_flag(trap_exit, true),
    ?assertExit(_, amqp_channel:call(Chan, make_exchange(Ex, Type))),
    amqp_connection:close(Conn),
    ok.

routing_topic_test() ->
    BKs = [<<"a.b.c">>, <<"a.*.c">>, <<"a.#">>],
    RKs = [<<"a.b.c">>, <<"a.z.c">>, <<"a.j.k">>, <<"b.b.c">>],
    %% all except <<"b.b.c">> should be routed.
    Count = 3,
    routing_test0(BKs, RKs, <<"topic">>, Count).

routing_direct_test() ->
    BKs = [<<"mykey">>],
    RKs = [<<"mykey">>, <<"noroute">>, <<"mykey">>],
    %% all except <<"noroute">> should be routed.
    Count = 2,
    routing_test0(BKs, RKs, <<"direct">>, Count).

routing_fanout_test() ->
    BKs = [<<"mykey">>, <<>>, <<"otherkey">>],
    RKs = [<<"mykey">>, <<"noroute">>, <<"mykey">>],
    %% all except <<"noroute">> should be routed.
    Count = 3,
    routing_test0(BKs, RKs, <<"fanout">>, Count).

routing_test0(BKs, RKs, ExType, Count) ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    Ex = <<"e1">>,
    Q = <<"q">>,

    [setup_fabric(Chan, make_exchange(Ex, ExType), make_queue(Q), BRK) ||
        BRK <- BKs],

    %% message delay will be 0, we are testing routing here
    Msgs = [0],

    amqp_channel:call(Chan, #'confirm.select'{}),

    [publish_messages(Chan, Ex, K, Msgs) ||
        K <- RKs],

    % ensure that the messages have been delivered to the queues
    % before asking for the message count
    amqp_channel:wait_for_confirms_or_die(Chan),

    #'queue.declare_ok'{message_count = MCount} =
        amqp_channel:call(Chan, make_queue(Q)),

    ?assertEqual(Count, MCount),

    amqp_channel:call(Chan, #'exchange.delete' { exchange = Ex }),
    amqp_channel:call(Chan, #'queue.delete' { queue = Q }),
    amqp_channel:close(Chan),
    amqp_connection:close(Conn),
    ok.

e2e_nodelay_test() ->
    %% message delay will be 0,
    %% we are testing e2e without delays
    e2e_test0([0]).

e2e_delay_test() ->
    %% message delay will be 0,
    %% we are testing e2e without delays
    e2e_test0([500, 100, 300, 200, 100, 400]).

e2e_test0(Msgs) ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    Ex = <<"e1">>,
    Ex2 = <<"e2">>,
    Q = <<"q">>,

    declare_exchange(Chan, make_exchange(Ex, <<"direct">>)),

    setup_fabric(Chan, make_exchange(Ex2, <<"direct">>), make_queue(Q)),

    #'exchange.bind_ok'{} =
        amqp_channel:call(Chan, #'exchange.bind' {
                                   source      = Ex,
                                   destination = Ex2
                                  }),


    publish_messages(Chan, Ex, Msgs),

    {ok, Result} = consume(Chan, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    amqp_channel:call(Chan, #'exchange.delete' { exchange = Ex }),
    amqp_channel:call(Chan, #'exchange.delete' { exchange = Ex2 }),
    amqp_channel:call(Chan, #'queue.delete' { queue = Q }),
    amqp_channel:close(Chan),
    amqp_connection:close(Conn),

    ok.

delay_order_test() ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    Ex = <<"e1">>,
    Q = <<"q">>,

    setup_fabric(Chan, make_exchange(Ex, <<"direct">>), make_queue(Q)),

    Msgs = [500, 100, 300, 200, 100, 400],

    publish_messages(Chan, Ex, Msgs),

    {ok, Result} = consume(Chan, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    ok.

node_restart_test() ->
    start_other_node(?HARE),

    {ok, Conn} = amqp_connection:start(#amqp_params_network{port=5673}),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    Ex = <<"e1">>,
    Q = <<"q">>,

    setup_fabric(Chan, make_durable_exchange(Ex, <<"direct">>),
                 make_durable_queue(Q)),

    Msgs = [5000, 1000, 3000, 2000, 1000, 4000],

    publish_messages(Chan, Ex, Msgs),

    amqp_channel:close(Chan),
    amqp_connection:close(Conn),

    stop_other_node(?HARE),
    start_other_node(?HARE),

    {ok, Conn2} = amqp_connection:start(#amqp_params_network{port=5673}),
    {ok, Chan2} = amqp_connection:open_channel(Conn2),

    {ok, Result} = consume(Chan2, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    amqp_channel:call(Chan2, #'exchange.delete' { exchange = Ex }),
    amqp_channel:call(Chan2, #'queue.delete' { queue = Q }),

    reset_other_node(?HARE),
    stop_other_node(?HARE),

    ok.

setup_fabric(Chan, ExDeclare, QueueDeclare) ->
    setup_fabric(Chan, ExDeclare, QueueDeclare, <<>>).

setup_fabric(Chan,
             ExDeclare = #'exchange.declare'{exchange = Ex},
             QueueDeclare,
             RK) ->
    declare_exchange(Chan, ExDeclare),

    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Chan, QueueDeclare),

    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind' {
                                   queue       = Q,
                                   exchange    = Ex,
                                   routing_key = RK
                                  }).

declare_exchange(Chan, ExDeclare) ->
    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan, ExDeclare).

publish_messages(Chan, Ex, Msgs) ->
    publish_messages(Chan, Ex, <<>>, Msgs).

publish_messages(Chan, Ex, RK, Msgs) ->
        [amqp_channel:call(Chan,
                           #'basic.publish'{exchange = Ex,
                                            routing_key = RK},
                           make_msg(V)) || V <- Msgs].

consume(Chan, Q, Msgs) ->
    #'basic.consume_ok'{} =
        amqp_channel:subscribe(Chan, #'basic.consume'{queue  = Q,
                                                      no_ack = true}, self()),
    collect(length(Msgs), lists:max(Msgs) + 1000).


collect(N, Timeout) ->
    collect(0, N, Timeout, []).

collect(N, N, _Timeout, Acc) ->
    {ok, lists:reverse(Acc)};
collect(Curr, N, Timeout, Acc) ->
    receive {#'basic.deliver'{},
             #amqp_msg{payload = Bin}} ->
            collect(Curr+1, N, Timeout, [binary_to_term(Bin) | Acc])
    after Timeout ->
            {error, {timeout, Acc}}
    end.

make_queue(Q) ->
    #'queue.declare' {
       queue       = Q
      }.

make_durable_queue(Q) ->
    QR = make_queue(Q),
    QR#'queue.declare'{
      durable     = true,
      auto_delete = false
     }.

make_exchange(Ex, Type) ->
    #'exchange.declare'{
       exchange    = Ex,
       type        = <<"x-delayed-message">>,
       arguments   = [{<<"x-delayed-type">>,
                       longstr, Type}]
      }.

make_durable_exchange(Ex, Type) ->
    ER = make_exchange(Ex, Type),
    ER#'exchange.declare'{
      durable     = true,
      auto_delete = false
     }.

make_msg(V) ->
    #amqp_msg{props = #'P_basic'{
                         headers = make_h(V)},
              payload = term_to_binary(V)}.

make_h(V) ->
    [{<<"x-delay">>, signedint, V}].

tests(Module, Timeout) ->
    {foreach, fun() -> ok end,
     [{timeout, Timeout, fun () -> Module:F() end} ||
         {F, _Arity} <- proplists:get_value(exports, Module:module_info()),
         string:right(atom_to_list(F), 5) =:= "_test"]}.
