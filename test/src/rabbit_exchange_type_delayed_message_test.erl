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

setup_fabric(Chan,
             ExDeclare = #'exchange.declare'{exchange = Ex},
             QueueDeclare) ->
    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan, ExDeclare),

    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Chan, QueueDeclare),

    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind' {
                                   queue = Q,
                                   exchange = Ex
                                  }).

publish_messages(Chan, Ex, Msgs) ->
        [amqp_channel:call(Chan,
                           #'basic.publish'{exchange = Ex},
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
    #'queue.declare' {
       queue       = Q,
       durable     = true,
       auto_delete = false
      }.

make_exchange(Ex, Type) ->
    #'exchange.declare' {
       exchange    = Ex,
       type        = <<"x-delayed-message">>,
       arguments   = [{<<"x-delayed-type">>,
                       longstr, Type}]
      }.

make_durable_exchange(Ex, Type) ->
    #'exchange.declare' {
       exchange    = Ex,
       type        = <<"x-delayed-message">>,
       durable     = true,
       auto_delete = false,
       arguments   = [{<<"x-delayed-type">>,
                       longstr, Type}]
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
