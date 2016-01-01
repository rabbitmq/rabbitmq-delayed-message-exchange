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

-module(rabbit_delayed_message_app).

-behaviour(application).
-export([start/2, stop/1]).

%% Same idea as for federation. We need to make sure
%% rabbit_delayed_message.erl is running to make it start publishing
%% delayed messages that might have been persisted but not published
%% yet.
-behaviour(supervisor).
-export([init/1]).

start(_Type, _StartArgs) ->
    rabbit_delayed_message:go(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_State) ->
    ok.
%%----------------------------------------------------------------------------

init([]) -> {ok, {{one_for_one, 3, 10}, []}}.
