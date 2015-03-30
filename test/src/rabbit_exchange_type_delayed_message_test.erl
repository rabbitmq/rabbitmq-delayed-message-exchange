-module(rabbit_exchange_type_delayed_message_test).

-export([test/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-define(RABBIT, {"rabbit-test",  5672}).
-define(HARE,   {"rabbit-hare", 5673}).

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

    [publish_messages(Chan, Ex, K, Msgs) ||
        K <- RKs],

    #'queue.declare_ok'{message_count = MCount} =
        amqp_channel:call(Chan, make_queue(Q)),

    %% all except <<"b.b.c">> should be routed.
    ?assertEqual(Count, MCount),

    amqp_channel:call(Chan, #'exchange.delete' { exchange = Ex }),
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

    Msgs = [5000, 1000, 3000, 2000, 1000, 4000],

    publish_messages(Chan, Ex, Msgs),

    Result = consume(Chan, Q, Msgs),

    Sorted = lists:sort(Msgs),
    {ok, Sorted} = Result,

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

    Result = consume(Chan2, Q, Msgs),

    Sorted = lists:sort(Msgs),
    {ok, Sorted} = Result,

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
    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan, ExDeclare),

    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Chan, QueueDeclare),

    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind' {
                                   queue       = Q,
                                   exchange    = Ex,
                                   routing_key = RK
                                  }).

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
