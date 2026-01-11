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

  It can take further options

  * `bucket: b` -- use bucket `b` to store the key-value pair
  * `pid: p` -- keep the key-value pair as long as pid `p` is alive
  * `node: n` -- keep the key-value pair as long as node `n` is connected
  * `key: k` -- keep the key-value pair as long as key `k` present
  * `until: u` -- keep the key-value pair until system time `u` (milliseconds)
  * `no_quorum: :retry | :fail | :return` -- Try again, crash or just return an
    error tuple when there's no quorum.

  The return value of the call is `{:ok, value}` when there's a consensus value
  for the `key`. The `value` returned is not always the `value` argument of the
  `PaxosKV.put` function, it can be a value proposed by another process. It can
  also return `{:error, reason}`, when something goes wrong.

  `{:error, :no_quorum}` means the cluster does not have enough nodes. In order
  to make a decision / reach consensus, more than `cluster_size / 2` nodes have
  to be part of the cluster. (Cluster size is a config param.) The option
  `:no_quorum` can change the behavior of `put`. Whern set to `:retry`, it
  won't return this tuple, but it will try again and again until it can reach
  enough nodes. The option `no_quorum: :fail` will generate an exception
  instead.

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

  It renurns `nil` when the key is not registered. The option `default: d`
  defines the value `d` that should be returned instead of nil when the key
  is not yet set or has been deleted.
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
  Returns the pid the key-vaue pair is bound to.  This is the pid set by the
  `pid: p` option in `put/3`.  `default: d` can be used the return `d` instead
  of `nil` when there's not pid set for the value or the key-value pair is not
  registered.
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
  Returns the node name the key-vaue pair is bound to.  This is the node set by
  the `node: n` option in `put/3`.  It returns `nil` when there is no node is
  bound to the key-vaue pair, or the key-value pair is not registered. The
  option `default: d` makes the call return d when it would return `nil`
  otherwise.
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
