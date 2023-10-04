%% Copyright (c) 2018 Pivotal Software Inc, All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%       https://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

-module(rabbit_delayed_message_machine).

-behaviour(ra_machine).

-record(state,
        {store = #{} :: #{term() => term()}}).

-export([init/1,
         apply/3,
         write/3,
         take/2,
         read/2]).

write(ServerReference, Key, Value) ->
    Cmd = {write, Key, Value},
    case ra:process_command(ServerReference, Cmd) of
        {ok, _, _} ->
            ok;
        {timeout, _} ->
            timeout
    end.

take(ServerReference, Key) ->
    Cmd = {take, Key},
    case ra:process_command(ServerReference, Cmd) of
        {ok, V, _} ->
            {ok, V};
        {timeout, _} ->
            timeout
    end.


read(ServerReference, Key) ->
    case ra:consistent_query(ServerReference,
                             fun(#state{store = Store}) ->
                                     maps:get(Key, Store, undefined)
                             end)
    of
        {ok, V, _} ->
            {ok, V};
        {timeout, _} ->
            timeout;
        {error, nodedown} ->
            error
    end.

init(_Config) ->
    #state{}.

apply(_Metadata,
      {write, Key, Value}, #state{store = Store0} = State0) ->
    Store1 = maps:put(Key, Value, Store0),
    State1 = State0#state{store = Store1},
    {State1, ok, []};
apply(_Metadata,
      {take, Key}, #state{store = Store0} = State0) ->
    {Value, Store1} = maps:take(Key, Store0),
    State1 = State0#state{store = Store1},
    {State1, Value, []}.
