load("@rules_erlang//:ct.bzl", "ct_test")

BROKER_VERSION_REQUIREMENTS_TERM = """{broker_version_requirements, ["3.11.0"]}"""

def rabbitmq_suite(
        name = None,
        additional_beam = [],
        additional_data = [],
        additional_deps = [],
        **kwargs):
    ct_test(
        name = name,
        compiled_suites = [":%s_beam_files" % name] + additional_beam,
        data = additional_data + native.glob([
            "test/%s_data/**/*" % name,
        ], exclude = additional_data),
        deps = [
            ":test_erlang_app",
        ] + additional_deps,
        **kwargs
    )

def rabbitmq_integration_suite(
        name = None,
        additional_beam = [],
        additional_data = [],
        additional_deps = [],
        additional_test_env = {},
        **kwargs):
    package = native.package_name()
    ct_test(
        name = name,
        compiled_suites = [":%s_beam_files" % name] + additional_beam,
        data = additional_data + native.glob([
            "test/%s_data/**/*" % name,
        ], exclude = additional_data),
        test_env = dict({
            "SKIP_MAKE_TEST_DIST": "true",
            "RABBITMQ_CT_SKIP_AS_ERROR": "true",
            "RABBITMQ_RUN": "$(location :rabbitmq-run)",
            "RABBITMQCTL": "$TEST_SRCDIR/$TEST_WORKSPACE/%s/broker-home/sbin/rabbitmqctl" % package,
            "RABBITMQ_PLUGINS": "$TEST_SRCDIR/$TEST_WORKSPACE/%s/broker-home/sbin/rabbitmq-plugins" % package,
            "RABBITMQ_QUEUES": "$TEST_SRCDIR/$TEST_WORKSPACE/%s/broker-home/sbin/rabbitmq-queues" % package,
            "LANG": "C.UTF-8",
        }.items() + additional_test_env.items()),
        tools = [
            ":rabbitmq-run",
        ],
        deps = [
            ":test_erlang_app",
            "@rabbitmq-server//deps/amqp_client:erlang_app",
            "@rabbitmq-server//deps/rabbit_common:erlang_app",
            "@rabbitmq-server//deps/rabbitmq_cli:elixir",
            "@rabbitmq-server//deps/rabbitmq_cli:erlang_app",
            "@rabbitmq-server//deps/rabbitmq_ct_client_helpers:erlang_app",
            "@rabbitmq-server//deps/rabbitmq_ct_helpers:erlang_app",
        ] + additional_deps,
        **kwargs
    )
