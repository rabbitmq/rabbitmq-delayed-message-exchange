# RabbitMQ Delayed Message Plugin

## Consider the Limitations

This plugin adds delayed-messaging (or scheduled-messaging) to
RabbitMQ. Its current design **has plenty of limitation** (documented below),
consider using an external scheduler and a data store that fits your needs
first.

This plugin badly needs a [new design](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/issues/229)
and a reimplementation from the ground up.

If you accept the limitations, please read on.

## The Basics

With this plugin enabled, a user can declare an exchange with the type `x-delayed-message` and
then publish messages with the custom header `x-delay` expressing in
milliseconds a delay time for the message. The message will be
delivered to the respective queues after `x-delay` milliseconds.

## Intended Use Cases

This plugin was designed for delaying message publishing for a number of seconds, minutes, or hours.
A day or two at most.

It is **not a longer term scheduling solution**. If you need to delay publishing by days, weeks, months, or years,
consider using a data store suitable for long-term storage, and an external scheduling tool
of some kind.


## Supported RabbitMQ Versions

The most recent release of this plugin targets RabbitMQ 4.0.x.

This plugin can be enabled on a RabbitMQ cluster that uses either Mnesia or Khepri as [metadata store](https://www.rabbitmq.com/docs/metadata-store),
however, when this plugin is enabled **before** Khepri, it must be restarted (or the node must be)
after Khepri is enabled.

In other words, there are three possible scenarios w.r.t. the schema data store used:

1. If the cluster uses Mnesia for schema store, it works exactly as it did against RabbitMQ 3.13.x
2. If the cluster uses Khepri and the plugin is enabled after Khepri, it will start Mnesia, set up a node-local Mnesia replica and schema, and works as in scenario 1
3. **Important**: if the cluster uses Mnesia, then the plugin is enabled, and then Khepri is enabled, the plugin must be disabled and re-enabled, or the node must be restarted.
   Then it will start Mnesia and works as in scenario 2

## Supported Erlang/OTP Versions

The latest version of this plugin [requires Erlang 26.2 or later versions](https://www.rabbitmq.com/which-erlang.html), same as RabbitMQ 4.0.x.

## Project Maturity

The current design of this plugin is **mature and potential suitable for production use
as long as the user is aware of its limitations and the intended use cases**.

This plugin is not commercially supported by VMware at the moment but
it doesn't mean that it will be abandoned or team RabbitMQ is not interested
in improving it in the future. It is not, however, a high priority for our small team.

So, give it a try with your workload and decide for yourself.


## Installation

### Download a Binary Build

Binary builds are distributed [via GitHub releases](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases).

As with all 3rd party plugins, the `.ez` file must be placed into a [node's plugins directory](https://rabbitmq.com/plugins.html#plugin-directories)
and be readable by the effective user of the RabbitMQ process.

To find out what the plugins directory is, use `rabbitmq-plugins directories`

``` bash
rabbitmq-plugins directories -s
```

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

Delayed messages are stored in a Mnesia table (also see Limitations below)
with a single disk replica on the current node. They will survive a node
restart. While timer(s) that triggered scheduled delivery are not persisted,
it will be re-initialised during plugin activation on node start.
Obviously, only having one copy of a scheduled message in a cluster means
that losing that node or disabling the plugin on it will lose the
messages residing on that node.

The plugin only performs one attempt at publishing each message but since publishing
is local, in practice the only issue that may prevent delivery is the lack of queues
(or bindings) to route to. 

Closely related to the above, the mandatory flag is not supported by this exchange:
we cannot be sure that at the future publishing point in time

 * there is at least one queue we can route to
 * the original connection is still around to send a `basic.return` to
 
Current design of this plugin doesn't really fit scenarios
with a high number of delayed messages (e.g. 100s of thousands or millions).
See [#72](https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/issues/72) for details.

## Disabling the Plugin ##

You can disable this plugin by calling `rabbitmq-plugins disable
rabbitmq_delayed_message_exchange` but note that **ALL DELAYED MESSAGES THAT
HAVEN'T BEEN DELIVERED WILL BE LOST**.

## Building the Plugin

```shell
bazel build //:erlang_app
bazel build :ez
```

The EZ file is created in the `bazel-bin` directory.

## Creating a Release

1. Update `broker_version_requirements` in `helpers.bzl` & `Makefile` (Optional)
1. Update the plugin version in `MODULE.bazel`
1. Push a tag (i.e. `v4.0.0`) with the matching version
1. Allow the Release workflow to run and create a draft release
1. Review and publish the release

## LICENSE

See the LICENSE file.
