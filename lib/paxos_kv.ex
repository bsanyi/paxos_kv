defmodule PaxosKV do
  @moduledoc "README.md" |> File.read!() |> String.replace(~r/^# PaxosKV/, "")

  alias PaxosKV.{Helpers, Proposer, Learner}

  @doc """
  Stores the given key-value pair in the collective memory of the cluster.

      PaxosKV.put(key, value)

  It can take further options

  * `bucket: b` -- use bucket `b` to store the key-value pair
  * `pid: p` -- keep the key-value pair as long as pid `p` is alive
  * `node: n` -- keep the key-value pair as long as node `n` is connected
  * `no_quorum: :retry | :fail | :return` -- Try again, crash or just return an
    error tuple when there's no quorum.
  """
  def put(key, value, opts \\ []) do
    case Proposer.propose(key, value, opts) do
      {:ok, {value, _meta}} ->
        value

      {:error, :invalid_value} ->
        nil

      {:error, :no_quorum} = error ->
        case Keyword.get(opts, :no_quorum, :retry) do
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
    case Learner.get(key, opts) do
      {value, _meta} -> value
      _ -> Keyword.get(opts, :default)
    end
  end

  @doc """
  Returns the pid the key-vaue pair is bound to.  This is the pid set by the
  `pid: p` option in `put/3`.  `default: d` can be used the return `d` instead
  of `nil` when there's not pid set for the value or the key-value pair is not
  registered.
  """
  def pid(key, opts \\ []) do
    case Learner.get(key, opts) do
      {_value, %{pid: pid}} -> pid
      _ -> Keyword.get(opts, :default)
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
    case Learner.get(key, opts) do
      {_value, %{node: node}} -> node
      _ -> Keyword.get(opts, :default)
    end
  end
end
