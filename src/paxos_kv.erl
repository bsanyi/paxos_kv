-module(paxos_kv).

-export([put/2, put/3, get/1, get/2, pid/1]).

put(Key, Value) ->
  'Elixir.PaxosKV':put(Key, Value).

put(Key, Value, Pid) ->
  'Elixir.PaxosKV':put(Key, Value, [{pid, Pid}]).

get(Key) ->
  'Elixir.PaxosKV':get(Key).

get(Key, Default) ->
  'Elixir.PaxosKV':get(Key, Default).

pid(Key) ->
  'Elixir.PaxosKV':pid(Key).

