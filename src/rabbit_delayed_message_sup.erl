%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%%  Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_delayed_message_sup).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(supervisor2).

-define(SERVER, ?MODULE).

-export([start_link/0]).

-export([init/1, stop/0]).

-rabbit_boot_step({rabbit_delayed_message_supervisor,
                   [{description, "delayed message sup"},
                    {mfa,         {rabbit_sup, start_child, [?MODULE]}},
                    {requires,    kernel_ready},
                    {enables,     rabbit_exchange_type_delayed_message},
                    {cleanup,     {?MODULE, stop, []}}]}).

child(rabbit_leveled_bookie = Name) ->
    child(Name,
          rabbit_delayed_message_kv_store,
          leveled_bookie_start_link);
child(Name) ->
    child(Name, Name, start_link).
child(Name, M, F) ->
    #{id => Name,
      start => {M, F, []},
      restart => transient,
      shutdown => ?WORKER_WAIT,
      type => worker,
      modules => [M]}.

children() ->
    [child(N) || N <- [rabbit_delayed_message,
                       rabbit_delayed_message_kv_store,
                       rabbit_leveled_bookie,
                       rabbit_delayed_stream_reader]].

start_link() ->
    supervisor2:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10},
          children()}}.

stop() ->
    ok = supervisor:terminate_child(rabbit_sup, ?MODULE),
    ok = supervisor:delete_child(rabbit_sup, ?MODULE).
