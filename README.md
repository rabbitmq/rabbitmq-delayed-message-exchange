# RabbitMQ Delayed Message Plugin #

This plugin adds delayed-messaging (or scheduled-messaging) to
RabbitMQ.

A user can declare an exchange with the type `x-delayed-message` and
then publish messages with the custom header `x-delay` expressing in
milliseconds a delay time for the message. The message will be
delivered to the respective queues after `x-delay` milliseconds.

## Installing ##

Install the corresponding .ez files from our
[Community Plugins page](http://www.rabbitmq.com/community-plugins.html).

Then run the following command:

```bash
rabbitmq-plugins enable rabbitmq_delayed_message_exchange
```

## Usage ##

To use the delayed-messaging feature, declare an exchange with the
type `x-delayed-message`:

```erlang
... elided code ...

Declare = #'exchange.declare' {
              exchange    = <<"my-exchange">>",
              type        = <<"x-delayed-message">>,
              durable     = true,
              auto_delete = false,
              arguments   = [{<<"x-delayed-type">>,
                              longstr, <<"direct">>}]
      },
amqp_channel:call(Chan, Declare),

... more code ...
```

Note that we pass an extra header called `x-delayed-type`, more on it
under the _Routing_ section.

Once we have the exchange declared we can publish messages providing a
header telling the plugin for how long to delay our messages:

```erlang
... elided code ...
amqp_channel:call(Chan,
                  #'basic.publish'{exchange = Ex},
                  #amqp_msg{props   = #'P_basic'{headers = [{<<"x-delay">>, signedint, 5000}]},
                            payload = <<"delayed payload">>}),

amqp_channel:call(Chan,
                  #'basic.publish'{exchange = Ex},
                  #amqp_msg{props   = #'P_basic'{headers = [{<<"x-delay">>, signedint, 1000}]},
                            payload = <<"more delayed payload">>}),

... more code ...
```

In the above example we publish two messages, specifying the delay
time with the `x-delay` header. For this example, the plugin will
deliver to our queues first the message with the body `<<"more delayed
payload">>` and then the one with the body `<<delayed payload">>`.

If the `x-delay` header is not present, then the plugin will proceed
to route the message without delay.

## Routing ##

This plugin allows for flexible routing via the `x-delayed-type`
arguments that can be passed during `exchange.declare`. In the example
above we used `<<"direct">>` as exchange type. That means the plugin
will have the same routing behavior shown by the direct exchange.

If you want a different routing behavior, then you could provide a
different exchange type, like `<<"topic">>` for example. You can also
specify exchange types provided by plugins. Note that this argument is
**required** and **must** refer to an **existing exchange type**.

## Disabling the Plugin ##

You can disable this plugin by calling `rabbitmq-plugins disable
rabbitmq_delayed_messaging` but note that **ALL DELAYED MESSAGES THAT
HAVEN'T BEEN DELIVERED WILL BE LOST**.

## Plugin Status ##

At the moment the plugin is **experimental** in order to receive
feedback from the community.

## LICENSE ##

See the LICENSE file.
