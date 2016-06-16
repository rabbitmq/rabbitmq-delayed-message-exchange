%%  The contents of this file are subject to the Mozilla Public License
%%  Version 2.0 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ Delayed Message
%%
%%  The Initial Developer of the Original Code is Pivotal Software, Inc.
%%  Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
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

start_link() ->
    supervisor2:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10},
          [{rabbit_delayed_message, {rabbit_delayed_message, start_link, []},
            transient, ?WORKER_WAIT, worker, [rabbit_delayed_message]}]}}.

stop() ->
    ok = supervisor:terminate_child(rabbit_sup, ?MODULE),
    ok = supervisor:delete_child(rabbit_sup, ?MODULE).
