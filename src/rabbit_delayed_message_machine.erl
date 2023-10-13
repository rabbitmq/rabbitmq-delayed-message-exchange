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
         write/4,
         take/3,
         read/2]).

write(ServerReference, Ref, Key, Value) ->
    Cmd = {write, Ref, Key, Value},
    case ra:process_command(ServerReference, Cmd) of
        {ok, _, _} ->
            ok;
        {timeout, _} ->
            timeout
    end.

take(ServerReference, Ref, Key) ->
    Cmd = {take, Ref, Key},
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
      {write, Ref, Key, Value}, State) ->
    rabbit_log:debug("Before ~n",[]),
    spawn(fun() -> R = leveled_bookie:book_put(Ref, "foo", Key, Value, []),
                   rabbit_log:debug("Ref ~p~nKey~p~nValue~p~nresult ~p", [Ref, Key, Value, R])
          end),
    {State, ok, []};
apply(_Metadata,
      {take, Ref, Key}, State) ->
    spawn(fun() -> leveled_bookie:book_delete(Ref, "foo", Key, []) end),
    {State, ok, []}.
