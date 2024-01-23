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

-module(rabbit_delayed_message_kv_store).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("rabbit_common/include/logging.hrl").

-behaviour(gen_server).

-export([start_link/0, leveled_bookie_start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).


-export([setup/0, maybe_make_cluster/0, maybe_resize_cluster/0]).

-export([
         delete/1,
         do_write/2,
         do_delete/1,
         do_take/1
         ]).

-record(state,
        {kv_store_pid,
         connection
        }).

-define(RA_SYSTEM, delayed_message_exchange).
-define(RA_CLUSTER_NAME, dmx_kv_cluster).

delete(Key) ->
    rabbit_delayed_message_machine:delete({?RA_CLUSTER_NAME, node()},
                                          Key).


setup() ->
    %% create connection
    %% create channel
    %% create queue
    ok = ensure_ra_system_started(?RA_SYSTEM).

maybe_make_cluster() ->
    Local = {?RA_CLUSTER_NAME, node()},
    Nodes = rabbit_nodes:list_reachable(),
    %% This might be overkill?
    case whereis(?RA_CLUSTER_NAME) of
        undefined ->
            global:set_lock({?RA_CLUSTER_NAME, self()}),
            case ra:restart_server(?RA_SYSTEM, Local) of
                {error, Reason} when Reason == not_started orelse
                                     Reason == name_not_registered ->
                    OtherNodes = Nodes -- [node()],
                    case lists:filter(
                           fun(N) ->
                                   erpc:call(N, erlang, whereis, [?RA_CLUSTER_NAME]) =/= undefined
                           end, OtherNodes) of
                        [] ->
                            ra:start_cluster(?RA_SYSTEM, [make_ra_conf(Node, Nodes) || Node <-  Nodes]),
                            QName = rabbit_misc:r(<<"/">>, queue, <<"internal-dmx-queue">>),
                            rabbit_amqqueue:declare(QName,
                                                    true,
                                                    false,
                                                    [{<<"x-queue-type">>, longstr, <<"stream">>}],
                                                    none, <<"dmx">>, node());
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end,
            global:del_lock({?RA_CLUSTER_NAME, self()});
        _ ->
            maybe_resize_cluster(),
            ok
    end,
    ok.


maybe_resize_cluster() ->
    case ra:members({?RA_CLUSTER_NAME, node()}) of
        {_, Members, _} ->
            MemberNodes = [Node || {_, Node} <- Members],
            Running = rabbit_nodes:list_running(),
            All = rabbit_nodes:list_members(),
            case Running -- MemberNodes of
                [] ->
                    ok;
                New ->
                    rabbit_log:info("~ts: New rabbit node(s) detected, "
                                    "adding : ~w",
                                    [?RA_CLUSTER_NAME, New]),
                    add_members(Members, New)
            end,
            case MemberNodes -- All of
                [] ->
                    ok;
                Old ->
                    rabbit_log:info("~ts: Rabbit node(s) removed from the cluster, "
                                    "deleting: ~w", [?RA_CLUSTER_NAME, Old]),
                    remove_members(Members, Old)
            end;
        _ ->
            ok
    end.

add_members(_, []) ->
    ok;
add_members(Members, [Node | Nodes]) ->
    Conf = make_ra_conf(Node, [N || {_, N} <- Members]),
    case ra:start_server(?RA_SYSTEM, Conf) of
        ok ->
            R = rabbit_stream_queue:add_replica(<<"/">>, <<"internal-dmx-queue">>, Node),
            rabbit_log:debug(">>> add replica deubg resutl ~p", [R]),
            case ra:add_member(Members, {?RA_CLUSTER_NAME, Node}) of
                {ok, NewMembers, _} ->
                    add_members(NewMembers, Nodes);
                _ ->
                    add_members(Members, Nodes)
            end;
        Error ->
            rabbit_log:warning("dmx failed to start on node ~ts : ~W",
                               [Node, Error, 10]),
            add_members(Members, Nodes)
    end.

remove_members(_, []) ->
    ok;
remove_members(Members, [Node | Nodes]) ->
    case ra:remove_member(Members, {?RA_CLUSTER_NAME, Node}) of
        {ok, NewMembers, _} ->
            remove_members(NewMembers, Nodes);
        _ ->
            remove_members(Members, Nodes)
    end.


make_ra_conf(Node, Nodes) ->
    UId = ra:new_uid(ra_lib:to_binary(?RA_CLUSTER_NAME)),
    Members = [{?RA_CLUSTER_NAME, N} || N <- Nodes],
    #{cluster_name => ?RA_CLUSTER_NAME,
      id => {?RA_CLUSTER_NAME, Node},
      uid => UId,
      friendly_name => atom_to_list(?RA_CLUSTER_NAME),
      initial_members => Members,
      log_init_args => #{uid => UId},
      machine => {module, rabbit_delayed_message_machine, #{}}
     }.


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
get_config(RaSystem) ->
    DefaultConfig = get_default_config(),
    CoordDataDir = filename:join(
                     [rabbit:data_dir(), "dmx", node()]),
    DefaultConfig#{name => RaSystem,
                   data_dir => CoordDataDir,
                   wal_data_dir => CoordDataDir,
                   wal_max_size_bytes => ?COORD_WAL_MAX_SIZE_B,
                   names => ra_system:derive_names(RaSystem)}.

get_default_config() ->
    ra_system:default_config().



start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


leveled_bookie_start_link() ->
    DataDir = filename:join(
                [rabbit:data_dir(), "dmx", node()]),
    Result = {ok, Pid} = leveled_bookie:book_start([{root_path, DataDir},
                                                    {log_level, error}]),
    register(rabbit_leveled_bookie, Pid),
    Result.

init([]) ->
    {ok, #state{kv_store_pid = rabbit_leveled_bookie}}.


do_write(Key, Value) ->
    gen_server:cast(?MODULE, {write, Key, Value}).

do_delete(Key) ->
    gen_server:cast(?MODULE, {delete, Key}).

do_take(Key) ->
    gen_server:call(?MODULE, {take, Key}).

handle_call({take, Key}, _From, #state{kv_store_pid = Ref} = State) ->
    Value = case leveled_bookie:book_get(whereis(Ref), "foo", Key) of
                {ok, V} -> V;
                not_found -> not_found
            end,
    {reply, Value, State}.

handle_cast({write, Key, Value}, #state{kv_store_pid = Ref} = State) ->
    leveled_bookie:book_put(whereis(Ref), "foo", Key, Value, []),
    {noreply, State};
handle_cast({delete, Key}, #state{kv_store_pid = Ref} = State) ->
    leveled_bookie:book_delete(whereis(Ref), "foo", Key, []),
    {noreply, State}.

handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) -> {ok, State}.
