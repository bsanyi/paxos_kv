-module(paxos_kv).

-if(?OTP_RELEASE >= 28).
-moduledoc """
Erlang interface for the PaxosKV distributed key-value store.

This module provides an Erlang-friendly API for interacting with the PaxosKV
system, which is a distributed, fault-tolerant key-value store built on the
Paxos consensus algorithm. All operations are forwarded to the underlying
Elixir implementation.

## Features

- Distributed consensus using Multi-Paxos
- Automatic key-based sharding across cluster nodes
- Fault tolerance and high availability
- Simple get/put interface with optional parameters

## Example Usage

    % Store a value
    {ok, _} = paxos_kv:put(my_key, my_value).

    % Retrieve a value
    {ok, Value} = paxos_kv:get(my_key).

    % Store with expiration time
    ExpiryTime = paxos_kv:now() + 60000,
    {ok, _} = paxos_kv:put(session, data, [{until, ExpiryTime}]).
""".
-endif.

-export([put/2, put/3, get/1, get/2, keys/0, keys/1, pid/1, node/1, now/0]).

-if(?OTP_RELEASE >= 28).
-doc """
Stores a key-value pair in the distributed store.

This operation uses the Paxos consensus algorithm to ensure the value is
safely replicated across the cluster. The key is automatically routed to
the appropriate node based on consistent hashing.

Note: The returned value may not be the same as the value argument if another
process has already set a different value for the key. Once a key has a consensus
value, it cannot be changed.

## Parameters

- `Key`: The key under which to store the value (any Erlang term)
- `Value`: The value to store (any Erlang term)

## Returns

- `{ok, Value}` when consensus is reached for the key
- `{error, invalid_value}` when the value is invalid
- `{error, no_quorum}` when the cluster doesn't have enough nodes

## Examples

    % Store a simple value
    {ok, <<"John Doe">>} = paxos_kv:put(user_123, <<"John Doe">>).

    % Store complex terms
    {ok, _} = paxos_kv:put({session, 456}, #{user => john}).

    % Store any Erlang term
    {ok, Config} = paxos_kv:put(config, [{port, 8080}, {host, "localhost"}]).
""".
-endif.
put(Key, Value) ->
  'Elixir.PaxosKV':put(Key, Value).

-if(?OTP_RELEASE >= 28).
-doc """
Stores a key-value pair in the distributed store with additional options.

This is the extended version of `put/2` that allows you to specify lifecycle
management and behavior options for the key-value pair.

Note: The returned value may not be the same as the value argument if another
process has already set a different value for the key. Once a key has a consensus
value, it cannot be changed.

## Parameters

- `Key`: The key under which to store the value (any Erlang term)
- `Value`: The value to store (any Erlang term)
- `Options`: A list of options (keyword list)

## Options

- `{bucket, Bucket}`: Use bucket Bucket to store the key-value pair
- `{pid, Pid}`: Keep the key-value pair as long as pid Pid is alive
- `{node, Node}`: Keep the key-value pair as long as node Node is connected
- `{key, Key}`: Keep the key-value pair as long as key Key is present
- `{until, Timestamp}`: Keep the key-value pair until system time Timestamp
  (in milliseconds). This defines the expiration time of the key-value pair.
- `{no_quorum, Behavior}`: Controls behavior when there's no quorum:
  - `return` (default) - returns `{error, no_quorum}`
  - `retry` - retries until quorum is reached (blocks indefinitely)
  - `fail` - throws an exception

## Returns

- `{ok, Value}` when consensus is reached for the key
- `{error, invalid_value}` when the value is invalid
- `{error, no_quorum}` when the cluster doesn't have enough nodes (default behavior)

## Examples

    % Store with default options
    {ok, _} = paxos_kv:put(my_key, my_value, []).

    % Store with expiration time (TTL)
    ExpiryTime = paxos_kv:now() + 60000,
    {ok, <<"session_data">>} = paxos_kv:put(session_key, <<"session_data">>,
                                             [{until, ExpiryTime}]).

    % Store bound to a process lifetime
    Pid = spawn(fun() -> timer:sleep(5000) end),
    {ok, _} = paxos_kv:put(temp_key, temp_value, [{pid, Pid}]).

    % Store bound to a node connection
    {ok, _} = paxos_kv:put(node_config, config_data,
                           [{node, 'node1@localhost'}]).

    % Store with retry on no quorum
    {ok, _} = paxos_kv:put(critical_key, data, [{no_quorum, retry}]).
""".
-endif.
put(Key, Value, Options) ->
  'Elixir.PaxosKV':put(Key, Value, Options).

-if(?OTP_RELEASE >= 28).
-doc """
Retrieves a value from the distributed store by its key.

This operation queries the Paxos cluster to retrieve the latest committed
value for the given key. The request is automatically routed to the
appropriate node.

## Parameters

- `Key`: The key to look up (any Erlang term)

## Returns

- `{ok, Value}` when the key is registered
- `{error, not_found}` when the key is not registered
- `{error, no_quorum}` when the cluster doesn't have enough nodes to reach consensus

## Examples

    % Retrieve a value
    case paxos_kv:get(user_123) of
        {ok, User} ->
            io:format("Found user: ~p~n", [User]);
        {error, not_found} ->
            io:format("User not found~n");
        {error, no_quorum} ->
            io:format("No quorum available~n")
    end.

    % Simple pattern match
    {ok, Value} = paxos_kv:get(my_key).
""".
-endif.
get(Key) ->
  'Elixir.PaxosKV':get(Key).

-if(?OTP_RELEASE >= 28).
-doc """
Returns a list of all keys stored in the cluster.

This function queries all nodes in the cluster and returns a deduplicated
list of all keys that have been stored in the default bucket ('Elixir.PaxosKV').

## Returns

- A list of keys (any Erlang terms)

## Examples

    % Store some values
    {ok, _} = paxos_kv:put(user_name, <<"Alice">>).
    {ok, _} = paxos_kv:put(counter, 42).

    % Get all keys
    Keys = paxos_kv:keys().
    % Keys = [user_name, counter]

    % Use the keys to iterate over all values
    lists:foreach(fun(Key) ->
        {ok, Value} = paxos_kv:get(Key),
        io:format("~p: ~p~n", [Key, Value])
    end, Keys).
""".
-endif.
keys() ->
  'Elixir.PaxosKV':keys().

-if(?OTP_RELEASE >= 28).
-doc """
Returns a list of all keys stored in the specified bucket.

This function queries all nodes in the cluster and returns a deduplicated
list of all keys that have been stored in the specified bucket namespace.
Buckets allow you to partition your key-value data into separate logical
namespaces.

## Parameters

- `Bucket`: The bucket (namespace) to query for keys (any Erlang term)

## Returns

- A list of keys (any Erlang terms)

## Examples

    % Store values in a custom bucket
    {ok, _} = paxos_kv:put(config_key, config_value, [{bucket, 'MyBucket'}]).
    {ok, _} = paxos_kv:put(setting_key, setting_value, [{bucket, 'MyBucket'}]).

    % Get all keys from the custom bucket
    BucketKeys = paxos_kv:keys('MyBucket').
    % BucketKeys = [config_key, setting_key]

    % Get all keys from the default bucket
    DefaultKeys = paxos_kv:keys('Elixir.PaxosKV').

    % Compare keys across different buckets
    AllBuckets = ['Elixir.PaxosKV', 'MyBucket', 'AnotherBucket'],
    AllKeys = lists:flatten([paxos_kv:keys(B) || B <- AllBuckets]).
""".
-endif.
keys(Bucket) ->
  'Elixir.PaxosKV':keys(Bucket).

-if(?OTP_RELEASE >= 28).
-doc """
Retrieves a value from the distributed store by its key with additional options.

This is the extended version of `get/1` that allows you to specify a default
value to return when the key is not found.

## Parameters

- `Key`: The key to look up (any Erlang term)
- `Options`: A list of options (keyword list)

## Options

- `{default, Value}`: Defines the value that should be returned (as `{ok, Value}`)
  when the key is not yet set or has been deleted.

## Returns

- `{ok, Value}` when the key is registered
- `{ok, Default}` when the key is not found and the `default` option is provided
- `{error, not_found}` when the key is not registered and no default is provided
- `{error, no_quorum}` when the cluster doesn't have enough nodes to reach consensus

## Examples

    % Retrieve with default options
    {ok, Value} = paxos_kv:get(my_key, []).

    % Retrieve with a default value
    {ok, Value} = paxos_kv:get(non_existent_key, [{default, <<"default">>}]).

    % Handle missing keys gracefully
    case paxos_kv:get(user_key, [{default, #{name => <<"Guest">>}}]) of
        {ok, User} ->
            io:format("User: ~p~n", [User])
    end.
""".
-endif.
get(Key, Options) ->
  'Elixir.PaxosKV':get(Key, Options).

-if(?OTP_RELEASE >= 28).
-doc """
Returns the pid the key-value pair is bound to.

This function returns the pid that was set via the `{pid, Pid}` option in
`put/3`. The key-value pair will be automatically deleted when this process
terminates.

## Parameters

- `Key`: The key to look up (any Erlang term)

## Returns

- `{ok, Pid}` when a pid is associated with the key
- `{error, not_found}` when the key is not registered
- `{error, no_quorum}` when the cluster doesn't have enough nodes to reach consensus

## Examples

    % Store a value bound to a process
    Pid = spawn(fun() -> timer:sleep(5000) end),
    {ok, _} = paxos_kv:put(session, <<"session_data">>, [{pid, Pid}]).

    % Get the associated pid
    {ok, Pid} = paxos_kv:pid(session).
    io:format("Session is bound to process: ~p~n", [Pid]).

    % Check if the bound process is still alive
    case paxos_kv:pid(session) of
        {ok, Pid} ->
            case erlang:is_process_alive(Pid) of
                true -> io:format("Bound process is alive~n");
                false -> io:format("Bound process is dead~n")
            end;
        {error, not_found} ->
            io:format("Session not found~n")
    end.
""".
-endif.
pid(Key) ->
  'Elixir.PaxosKV':pid(Key).

-if(?OTP_RELEASE >= 28).
-doc """
Returns the node name the key-value pair is bound to.

This function returns the node name that was set via the `{node, Node}` option
in `put/3`. The key-value pair will be automatically deleted when this node
disconnects from the cluster.

## Parameters

- `Key`: The key to look up (any Erlang term)

## Returns

- `{ok, Node}` when a node is associated with the key
- `{error, not_found}` when the key is not registered
- `{error, no_quorum}` when the cluster doesn't have enough nodes to reach consensus

## Examples

    % Store a value bound to a node
    {ok, _} = paxos_kv:put(node_config, config_data,
                           [{node, 'node1@localhost'}]).

    % Get the associated node
    {ok, Node} = paxos_kv:node(node_config).
    io:format("Config is bound to node: ~p~n", [Node]).

    % Check if the bound node is still connected
    case paxos_kv:node(node_config) of
        {ok, Node} ->
            case lists:member(Node, erlang:nodes()) of
                true -> io:format("Bound node is connected~n");
                false -> io:format("Bound node is disconnected~n")
            end;
        {error, not_found} ->
            io:format("Config not found~n")
    end.
""".
-endif.
node(Key) ->
  'Elixir.PaxosKV':node(Key).

-if(?OTP_RELEASE >= 28).
-doc """
Returns the current time that can be used in the `until` option.

The time is measured in milliseconds and is actually the system time. This is
a convenience function for creating timestamps for the `{until, Timestamp}`
option in `put/3`.

## Returns

- Current system time in milliseconds

## Examples

    % Get current time
    Now = paxos_kv:now().

    % Store with 60 second TTL
    ExpiryTime = paxos_kv:now() + 60000,
    {ok, _} = paxos_kv:put(session, data, [{until, ExpiryTime}]).

    % Store with 5 minute TTL
    {ok, _} = paxos_kv:put(cache_key, value, [{until, paxos_kv:now() + 300000}]).
""".
-endif.
now() ->
  'Elixir.PaxosKV':now().
