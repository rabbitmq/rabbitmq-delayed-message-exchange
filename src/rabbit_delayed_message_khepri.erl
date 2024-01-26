%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% NOTE that this module uses os:timestamp/0 but in the future Erlang
%% will have a new time API.
%% See:
%% https://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/erlang.html#now-0
%% and
%% https://www.erlang.org/documentation/doc-7.0-rc1/erts-7.0/doc/html/time_correction.html

-module(rabbit_delayed_message_khepri).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-export([setup/0,
         get_store_id/0,
         put/2,
         delete/1,
         get/1,
         match/1,
         get_many/1]).

-define(RA_SYSTEM, dmx_coordination).
-define(RA_CLUSTER_NAME, rabbitmq_dmx_metadata).
-define(RA_FRIENDLY_NAME, "RabbitMQ Delayed Message Exchange metadata store").
-define(STORE_ID, ?RA_CLUSTER_NAME).

setup() ->
    RaServerConfig = #{cluster_name => ?RA_CLUSTER_NAME,
                       friendly_name => ?RA_FRIENDLY_NAME},
    ok = ensure_ra_system_started(?RA_SYSTEM),
    case khepri:start(?RA_SYSTEM, RaServerConfig) of
        {ok, ?STORE_ID} ->
            wait_for_leader(),
            %register_projections() would this be needed for dmx?
            ok;
        {error, _} = Error ->
            exit(Error)
    end.

get_store_id() ->
    ?STORE_ID.

ensure_ra_system_started(RaSystem) ->
    RaSystemConfig = get_config(RaSystem),
    ?LOG_DEBUG(
       "Starting Ra system called \"~ts\" with configuration:~n~tp",
       [RaSystem, RaSystemConfig],
       #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
    case ra_system:start(RaSystemConfig) of
        {ok, _} ->
            ?LOG_DEBUG(
               "Ra system \"~ts\" ready",
               [RaSystem],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            ok;
        {error, {already_started, _}} ->
            ?LOG_DEBUG(
               "Ra system \"~ts\" ready",
               [RaSystem],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            ok;
        Error ->
            ?LOG_ERROR(
               "Failed to start Ra system \"~ts\": ~tp",
               [RaSystem, Error],
               #{domain => ?RMQLOG_DOMAIN_GLOBAL}),
            throw(Error)
    end.

-define(COORD_WAL_MAX_SIZE_B, 64_000_000).
get_config(dmx_coordination = RaSystem) ->
    DefaultConfig = get_default_config(),
    CoordDataDir = filename:join(
                     [rabbit:data_dir(), "dmx_coordination", node()]),
    DefaultConfig#{name => RaSystem,
                   data_dir => CoordDataDir,
                   wal_data_dir => CoordDataDir,
                   wal_max_size_bytes => ?COORD_WAL_MAX_SIZE_B,
                   names => ra_system:derive_names(RaSystem)}.

get_default_config() ->
    ra_system:default_config().

wait_for_leader() ->
    wait_for_leader(retry_timeout(), retry_limit()).

retry_timeout() ->
    case application:get_env(rabbit, khepri_leader_wait_retry_timeout) of
        {ok, T}   -> T;
        undefined -> 30000
    end.

retry_limit() ->
    case application:get_env(rabbit, khepri_leader_wait_retry_limit) of
        {ok, T}   -> T;
        undefined -> 10
    end.

wait_for_leader(_Timeout, 0) ->
    exit(timeout_waiting_for_leader);
wait_for_leader(Timeout, Retries) ->
    rabbit_log:info("DMX: Waiting for Khepri leader for ~tp ms, ~tp retries left",
                    [Timeout, Retries - 1]),
    Options = #{timeout => Timeout,
                favor => compromise},
    case khepri:exists(?STORE_ID, [], Options) of
        Exists when is_boolean(Exists) ->
            rabbit_log:info("DMX: Khepri leader elected"),
            ok;
        {error, {timeout, _ServerId}} ->
            wait_for_leader(Timeout, Retries -1);
        {error, Reason} ->
            throw(Reason)
    end.

put(PathPattern, Data) ->
    khepri:put(?STORE_ID, PathPattern, Data).

get(PathPattern) ->
    khepri:get(?STORE_ID, PathPattern).

delete(PathPattern) ->
    khepri:delete(?STORE_ID, PathPattern).

get_many(PathPattern) ->
    khepri:get_many(?STORE_ID, PathPattern).

match(PathPattern) ->
    khepri:get_many(?STORE_ID, PathPattern).
