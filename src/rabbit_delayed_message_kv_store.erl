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

-export([setup/0, maybe_make_cluster/0, maybe_resize_cluster/0]).

-export([
         write/3,
         take/2
         ]).

-define(RA_SYSTEM, delayed_message_exchange).

write(Ref, Key, Value) ->
    rabbit_delayed_message_machine:write({?MODULE, node()},
                                         Ref,
                                         Key,
                                         Value).

take(Ref, Key) ->
    rabbit_delayed_message_machine:take({?MODULE, node()},
                                        Ref, Key).


setup() ->
    ok = ensure_ra_system_started(?RA_SYSTEM).

maybe_make_cluster() ->
    Local = {?MODULE, node()},
    Nodes = rabbit_nodes:list_reachable(),
    %% This might be overkill?
    case whereis(?MODULE) of
        undefined ->
            global:set_lock({?MODULE, self()}),
            case ra:restart_server(?RA_SYSTEM, Local) of
                {error, Reason} when Reason == not_started orelse
                                     Reason == name_not_registered ->
                    OtherNodes = Nodes -- [node()],
                    rabbit_log:debug(">>>> OTHER NODES ~p", [OtherNodes]),
                    case lists:filter(
                           fun(N) ->
                                   erpc:call(N, erlang, whereis, [?MODULE]) =/= undefined
                           end, OtherNodes) of
                        [] ->
                            ra:start_cluster(?RA_SYSTEM, [make_ra_conf(Node, Nodes) || Node <-  Nodes]);
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end,
            global:del_lock({?MODULE, self()});
        _ ->
            maybe_resize_cluster(),
            ok
    end,
    ok.


maybe_resize_cluster() ->
    case ra:members({?MODULE, node()}) of
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
                                    [?MODULE, New]),
                    add_members(Members, New)
            end,
            case MemberNodes -- All of
                [] ->
                    ok;
                Old ->
                    rabbit_log:info("~ts: Rabbit node(s) removed from the cluster, "
                                    "deleting: ~w", [?MODULE, Old]),
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
            case ra:add_member(Members, {?MODULE, Node}) of
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
    case ra:remove_member(Members, {?MODULE, Node}) of
        {ok, NewMembers, _} ->
            remove_members(NewMembers, Nodes);
        _ ->
            remove_members(Members, Nodes)
    end.


make_ra_conf(Node, Nodes) ->
    UId = ra:new_uid(ra_lib:to_binary(?MODULE)),
    Members = [{?MODULE, N} || N <- Nodes],
    #{cluster_name => ?MODULE,
      id => {?MODULE, Node},
      uid => UId,
      friendly_name => atom_to_list(?MODULE),
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
