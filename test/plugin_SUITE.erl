%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(plugin_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

all() ->
    [
      {group, non_parallel_tests}
    ].

groups() ->
    [
      {non_parallel_tests, [], [
                                wrong_exchange_argument_type,
                                exchange_argument_type_not_self,
                                routing_topic,
                                routing_direct,
                                routing_fanout,
                                e2e_nodelay,
                                e2e_delay,
                                delay_order,
                                delayed_messages_count,
                                node_restart_before_delay_expires,
                                node_restart_after_delay_expires,
                                string_delay_header
                               ]}
    ].


%% -------------------------------------------------------------------
%% Setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE}
      ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()).

init_per_group(_, Config) ->
    Config.

end_per_group(_, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    TestCaseName = rabbit_ct_helpers:config_to_testcase_name(Config, Testcase),
    BaseName = re:replace(TestCaseName, "/", "-", [global,{return,list}]),
    Config1 = rabbit_ct_helpers:set_config(Config, {test_resource_name, BaseName}),
    rabbit_ct_helpers:testcase_started(Config1, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testcases
%% -------------------------------------------------------------------

wrong_exchange_argument_type(Config) ->
    Chan =  rabbit_ct_client_helpers:open_channel(Config),
    Ex = make_exchange_name(Config, "fail"),
    Type = <<"x-not-valid-type">>,
    process_flag(trap_exit, true),
    ?assertExit(_, amqp_channel:call(Chan, make_exchange(Ex, Type))),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

exchange_argument_type_not_self(Config) ->
    Chan =  rabbit_ct_client_helpers:open_channel(Config),
    Ex = make_exchange_name(Config, "1"),
    Type = <<"x-delayed-message">>,
    process_flag(trap_exit, true),
    ?assertExit(_, amqp_channel:call(Chan, make_exchange(Ex, Type))),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

routing_topic(Config) ->
    BKs = [<<"a.b.c">>, <<"a.*.c">>, <<"a.#">>],
    RKs = [<<"a.b.c">>, <<"a.z.c">>, <<"a.j.k">>, <<"b.b.c">>],
    %% all except <<"b.b.c">> should be routed.
    Count = 3,
    routing_test0(Config, BKs, RKs, <<"topic">>, Count).

routing_direct(Config) ->
    BKs = [<<"mykey">>],
    RKs = [<<"mykey">>, <<"noroute">>, <<"mykey">>],
    %% all except <<"noroute">> should be routed.
    Count = 2,
    routing_test0(Config, BKs, RKs, <<"direct">>, Count).

routing_fanout(Config) ->
    BKs = [<<"mykey">>, <<>>, <<"otherkey">>],
    RKs = [<<"mykey">>, <<"noroute">>, <<"mykey">>],
    %% all except <<"noroute">> should be routed.
    Count = 3,
    routing_test0(Config, BKs, RKs, <<"fanout">>, Count).

routing_test0(Config, BKs, RKs, ExType, Count) ->
    Chan =  rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Q = make_queue_name(Config, "1"),

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
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

e2e_nodelay(Config) ->
    %% message delay will be 0,
    %% we are testing e2e without delays
    e2e_test0(Config, [0]).

e2e_delay(Config) ->
    e2e_test0(Config, [500, 100, 300, 200, 100, 400]).

e2e_test0(Config, Msgs) ->
    Chan =  rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Ex2 = make_exchange_name(Config, "2"),
    Q = make_queue_name(Config, "1"),

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
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

delay_order(Config) ->
    Chan =  rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Q = make_queue_name(Config, "1"),

    setup_fabric(Chan, make_exchange(Ex, <<"direct">>), make_queue(Q)),

    Msgs = [500, 100, 300, 200, 100, 400],

    publish_messages(Chan, Ex, Msgs),

    {ok, Result} = consume(Chan, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

delayed_messages_count(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Q = make_queue_name(Config, "1"),

    setup_fabric(Chan, make_exchange(Ex, <<"direct">>), make_queue(Q)),

    Msgs = [500, 200, 300, 200, 300, 400],

    publish_messages(Chan, Ex, Msgs),

    % Let messages schedule.
    timer:sleep(50),
    Exchanges = rabbit_ct_broker_helpers:rpc(Config, 0,
          rabbit_exchange, info_all, [<<"/">>]),

    FilterEx =
        fun(X) ->
                {resource, <<"/">>, exchange, Ex} == proplists:get_value(name, X)
        end,

    [Exchange] = lists:filter(FilterEx, Exchanges),
    {messages_delayed, 6} = proplists:lookup(messages_delayed, Exchange),

    %% Set a policy for the exchange
    PolicyName = make_policy_name(Config, "1"),
    rabbit_ct_broker_helpers:set_policy(
      Config, 0, PolicyName, <<"^", Ex/binary>>, <<"exchanges">>, [{<<"alternate-exchange">>, <<"altex">>}]),

    %% Same message count returned for modified exchange
    Exchanges2 = rabbit_ct_broker_helpers:rpc(Config, 0,
          rabbit_exchange, info_all, [<<"/">>]),

    [Exchange2] = lists:filter(FilterEx, Exchanges2),
    {messages_delayed, 6} = proplists:lookup(messages_delayed, Exchange2),

    consume(Chan, Q, Msgs),

    rabbit_ct_broker_helpers:clear_policy(Config, 0, PolicyName),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

node_restart_before_delay_expires(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Q = make_queue_name(Config, "1"),

    setup_fabric(Chan, make_durable_exchange(Ex, <<"direct">>),
                 make_durable_queue(Q)),

    %% Here, we suppose the node will be restarted before all messages
    %% are actually queued.
    Msgs = [5000, 10000, 3000, 2000, 15000, 1000, 4000],

    publish_messages(Chan, Ex, Msgs),

    rabbit_ct_broker_helpers:restart_node(Config, 0),

    Chan2 =  rabbit_ct_client_helpers:open_channel(Config),

    {ok, Result} = consume(Chan2, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    amqp_channel:call(Chan2, #'exchange.delete' { exchange = Ex }),
    amqp_channel:call(Chan2, #'queue.delete' { queue = Q }),

    rabbit_ct_client_helpers:close_channel(Chan2),

    ok.

node_restart_after_delay_expires(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config),

    Ex = make_exchange_name(Config, "1"),
    Q = make_queue_name(Config, "1"),

    setup_fabric(Chan, make_durable_exchange(Ex, <<"direct">>),
                 make_durable_queue(Q)),

    Msgs = [5000, 1000, 3000, 2000, 1000, 4000],

    publish_messages(Chan, Ex, Msgs),

    timer:sleep(lists:max(Msgs) + 3000),
    rabbit_ct_broker_helpers:restart_node(Config, 0),

    Chan2 =  rabbit_ct_client_helpers:open_channel(Config),

    {ok, Result} = consume(Chan2, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

    amqp_channel:call(Chan2, #'exchange.delete' { exchange = Ex }),
    amqp_channel:call(Chan2, #'queue.delete' { queue = Q }),

    rabbit_ct_client_helpers:close_channel(Chan2),

    ok.

string_delay_header(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config),

    Ex = <<"e3">>,
    Q = <<"q1">>,

    setup_fabric(Chan, make_exchange(Ex, <<"direct">>), make_queue(Q)),

    Msgs = [500, 100, 300, 200, 100, 400],

    publish_messages(Chan, Ex, <<>>, Msgs, longstr),

    {ok, Result} = consume(Chan, Q, Msgs),
    Sorted = lists:sort(Msgs),
    ?assertEqual(Sorted, Result),

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
    publish_messages(Chan, Ex, RK, Msgs, signedint).

publish_messages(Chan, Ex, RK, Msgs, HeaderType) ->
        [amqp_channel:call(Chan,
                           #'basic.publish'{exchange = Ex,
                                            routing_key = RK},
                           make_msg(HeaderType, V)) || V <- Msgs].

consume(Chan, Q, Msgs) ->
    #'basic.consume_ok'{} =
        amqp_channel:subscribe(Chan, #'basic.consume'{queue  = Q,
                                                      no_ack = true}, self()),
    collect(length(Msgs), lists:max(Msgs) + 3000).


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

make_msg(HeaderType, V) ->
    #amqp_msg{props = #'P_basic'{
                         delivery_mode = 2,
                         headers = make_h(HeaderType, V)},
              payload = term_to_binary(V)}.

make_h(V) ->
    make_h(signedint, V).

make_h(signedint, V) ->
    [{<<"x-delay">>, signedint, V}];
make_h(longstr, V) ->
    [{<<"x-delay">>, longstr, integer_to_binary(V)}].

tests(Module, Timeout) ->
    {foreach, fun() -> ok end,
     [{timeout, Timeout, fun () -> Module:F() end} ||
         {F, _Arity} <- proplists:get_value(exports, Module:module_info()),
         string:right(atom_to_list(F), 5) =:= "_test"]}.

make_exchange_name(Config, Suffix) ->
    B = rabbit_ct_helpers:get_config(Config, test_resource_name),
    erlang:list_to_binary("x-" ++ B ++ "-" ++ Suffix).

make_queue_name(Config, Suffix) ->
    B = rabbit_ct_helpers:get_config(Config, test_resource_name),
    erlang:list_to_binary("q-" ++ B ++ "-" ++ Suffix).

make_policy_name(Config, Suffix) ->
    B = rabbit_ct_helpers:get_config(Config, test_resource_name),
    erlang:list_to_binary("p-" ++ B ++ "-" ++ Suffix).
