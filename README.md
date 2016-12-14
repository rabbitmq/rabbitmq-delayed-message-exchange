# RabbitMQ Delayed Message Plugin #

This plugin adds delayed-messaging (or scheduled-messaging) to
RabbitMQ.

A user can declare an exchange with the type `x-delayed-message` and
then publish messages with the custom header `x-delay` expressing in
milliseconds a delay time for the message. The message will be
delivered to the respective queues after `x-delay` milliseconds.

## Supported RabbitMQ Versions

This plugin targets RabbitMQ 3.5.8 and later versions. The most recent
release is recommended. Note the Erlang requirement section below.

## Supported Erlang/OTP Versions

This plugin targets Erlang/OTP `18.0` and later versions (even if the RabbitMQ
version used can run on an older Erlang release). The most recent
release is recommended.

## Project Maturity

This plugin is considered to be **experimental yet fairly stable and reasonably suitable for production use**.
It had a few issues and one fundamental problem fixed in its ~ 18 months of
existence. It is known to work reasonably well for some users.
It also has known limitations (see a section below),
including those related to the number of delayed messages.

This plugin is not commercially supported by Pivotal at the moment but
it doesn't mean that it will be abandoned or team RabbitMQ is not interested
in improving it further. It is not, however, a high priority for our small team.

So, give it a try with your workload and decide for yourself.


## Installation

### Binary Builds

Binary builds are available from the
[RabbitMQ Community Plugins page](http://www.rabbitmq.com/community-plugins.html).

### Enabling the Plugin

Then run the following command:

``` bash
rabbitmq-plugins enable rabbitmq_delayed_message_exchange
```

## Usage ##

To use the delayed-messaging feature, declare an exchange with the
type `x-delayed-message`:


```java
// ... elided code ...
Map<String, Object> args = new HashMap<String, Object>();
args.put("x-delayed-type", "direct");
channel.exchangeDeclare("my-exchange", "x-delayed-message", true, false, args);
// ... more code ...
```

Note that we pass an extra header called `x-delayed-type`, more on it
under the _Routing_ section.

Once we have the exchange declared we can publish messages providing a
header telling the plugin for how long to delay our messages:

```java
// ... elided code ...
byte[] messageBodyBytes = "delayed payload".getBytes("UTF-8");
Map<String, Object> headers = new HashMap<String, Object>();
headers.put("x-delay", 5000);
AMQP.BasicProperties.Builder props = new AMQP.BasicProperties.Builder().headers(headers);
channel.basicPublish("my-exchange", "", props.build(), messageBodyBytes);

byte[] messageBodyBytes2 = "more delayed payload".getBytes("UTF-8");
Map<String, Object> headers2 = new HashMap<String, Object>();
headers2.put("x-delay", 1000);
AMQP.BasicProperties.Builder props2 = new AMQP.BasicProperties.Builder().headers(headers2);
channel.basicPublish("my-exchange", "", props2.build(), messageBodyBytes2);
// ... more code ...
```

In the above example we publish two messages, specifying the delay
time with the `x-delay` header. For this example, the plugin will
deliver to our queues first the message with the body `"more delayed
payload"` and then the one with the body `"delayed payload"`.

If the `x-delay` header is not present, then the plugin will proceed
to route the message without delay.

## Routing ##

This plugin allows for flexible routing via the `x-delayed-type`
arguments that can be passed during `exchange.declare`. In the example
above we used `"direct"` as exchange type. That means the plugin
will have the same routing behavior shown by the direct exchange.

If you want a different routing behavior, then you could provide a
different exchange type, like `"topic"` for example. You can also
specify exchange types provided by plugins. Note that this argument is
**required** and **must** refer to an **existing exchange type**.

## Performance Impact ##

Due to the `"x-delayed-type"` argument, one could use this exchange in
place of other exchanges, since the `"x-delayed-message"` exchange
will just act as proxy. Note that there might be some performance
implications if you do this.

For each message that crosses an `"x-delayed-message"` exchange, the
plugin will try to determine if the message has to be expired by
making sure the delay is within range, ie: `Delay > 0, Delay =<
?ERL_MAX_T` (In Erlang a timer can be set up to (2^32)-1 milliseconds
in the future).

If the previous condition holds, then the message will be persisted to
Mnesia and some other logic will kick in to determine if this
particular message delay needs to replace the current scheduled timer
and so on.

This means that while one _could_ use this exchange in place of a
_direct_ or _fanout_ exchange (or any other exchange for that matter),
_it will be slower_ than using the actual exchange. If you don't need
to delay messages, then use the actual exchange.

## Limitations

This plugin was created with disk nodes in mind. RAM nodes are currently
unsupported and adding support for them is not a priority (if you aren't sure
what RAM nodes are and whether you need to use them, you almost certainly don't).

Mandatory flag is not supported by this exchange: we cannot be sure that
at the future publishing point in time

 * there is at least one queue we can route to
 * the original connection is still around to send a `basic.return` to
 
Current design of this plugin doesn't really fit scenarios
with a high number of delayed messages (e.g. 100s of thousands or millions).
See #72 for details.

## Disabling the Plugin ##

You can disable this plugin by calling `rabbitmq-plugins disable
rabbitmq_delayed_message_exchange` but note that **ALL DELAYED MESSAGES THAT
HAVEN'T BEEN DELIVERED WILL BE LOST**.


## LICENSE ##

See the LICENSE file.
