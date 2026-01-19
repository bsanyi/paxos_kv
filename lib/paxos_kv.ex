defmodule PaxosKV do
  @moduledoc """
  `PaxosKV` is the main API module. Most of the time you should interact with
  the application via functions in this module.

  The most important function you need to know is `PaxosKV.put`.
  """

  alias PaxosKV.{Helpers, Proposer, Learner}

  @doc """
  Stores the given value under the key in the collective memory (a KV store) of
  the cluster.

      PaxosKV.put(key, value)
      PaxosKV.put(key, value, pid: self())

  The function returns:
  - `{:ok, value}` when consensus is reached for the key
  - `{:error, :invalid_value}` when the value is invalid
  - `{:error, :no_quorum}` when the cluster doesn't have enough nodes (default behavior)

  Note: The returned `value` may not be the same as the `value` argument if another
  process has already set a different value for the key. Once a key has a consensus
  value, it cannot be changed.

  ## Options

  * `bucket: b` -- use bucket `b` to store the key-value pair
  * `pid: p` -- keep the key-value pair as long as pid `p` is alive
  * `node: n` -- keep the key-value pair as long as node `n` is connected
  * `key: k` -- keep the key-value pair as long as key `k` is present
  * `until: u` -- keep the key-value pair until system time `u` (milliseconds)
  * `no_quorum: :retry | :fail | :return` -- controls behavior when there's no quorum:
    - `:return` (default) -- returns `{:error, :no_quorum}`
    - `:retry` -- retries until quorum is reached (blocks indefinitely)
    - `:fail` -- throws an exception

  To reach consensus, more than `cluster_size / 2` nodes must be part of the cluster.
  """
  def put(key, value, opts \\ []) do
    case Proposer.propose(key, value, opts) do
      {:ok, {value, _meta}} ->
        {:ok, value}

      {:error, :invalid_value} = error ->
        error

      {:error, :no_quorum} = error ->
        case Keyword.get(opts, :no_quorum, :return) do
          :retry ->
            Helpers.random_backoff()
            put(key, value, opts)

          :fail ->
            throw(error)

          :return ->
            error
        end
    end
  end

  @doc """
  Returns the value for the given key in the cluster.

  The function returns:
  - `{:ok, value}` when the key is registered
  - `{:ok, default}` when the key is not found and the `default: d` option is provided
  - `{:error, :not_found}` when the key is not registered and no default is provided
  - `{:error, :no_quorum}` when the cluster doesn't have enough nodes to reach consensus

  The option `default: d` defines the value `d` that should be returned (as `{:ok, d}`)
  when the key is not yet set or has been deleted.
  """
  def get(key, opts \\ []) do
    default? = Keyword.has_key?(opts, :default)
    case Learner.get(key, opts) do
      {:ok, {value, _meta}} -> {:ok, value}
      {:error, :not_found} when default? -> {:ok, Keyword.get(opts, :default)}
      error -> error
    end
  end

  @doc """
  Returns the pid the key-value pair is bound to. This is the pid set by the
  `pid: p` option in `put/3`.

  The function returns:
  - `{:ok, pid}` when a pid is associated with the key
  - `{:ok, default}` when the key is not found and the `default: d` option is provided
  - `{:error, :not_found}` when the key is not registered and no default is provided
  - `{:error, :no_quorum}` when the cluster doesn't have enough nodes to reach consensus
  """
  def pid(key, opts \\ []) do
    default? = Keyword.has_key?(opts, :default)
    case Learner.get(key, opts) do
      {:ok, {_value, %{pid: pid}}} -> {:ok, pid}
      {:error, :not_found} when default? -> {:ok, Keyword.get(opts, :default)}
      error -> error
    end
  end

  @doc """
  Returns the node name the key-value pair is bound to. This is the node set by
  the `node: n` option in `put/3`.

  The function returns:
  - `{:ok, node}` when a node is associated with the key
  - `{:ok, default}` when the key is not found and the `default: d` option is provided
  - `{:error, :not_found}` when the key is not registered and no default is provided
  - `{:error, :no_quorum}` when the cluster doesn't have enough nodes to reach consensus
  """
  def node(key, opts \\ []) do
    default? = Keyword.has_key?(opts, :default)
    case Learner.get(key, opts) do
      {:ok, {_value, %{node: node}}} -> {:ok, node}
      {:error, :not_found} when default? -> {:ok, Keyword.get(opts, :default)}
      error -> error
    end
  end
end
