defmodule PaxosKV do
  @moduledoc "README.md" |> File.read!() |> String.replace(~r/^# PaxosKV/, "")

  @doc """
  Stores the given key-value pair in the collective memory of the cluster.

      PaxosKV.put(key, value)

  It van take further options

  * `bucket: b` -- use bucket `b` to store the key-value pair
  * `pid: p` -- keep the key-value pair as long as pid `p` is alive
  * `node: n` -- keep the key-value pair as long as node `n` is connected
  """
  def put(key, value, opts \\ []) do
    case PaxosKV.Proposer.propose(key, value, opts) do
      {value, _meta} -> value
      nil -> nil
    end
  end

  @doc """
  Returns the value for the given key in the cluster.

  It renurns `nil` when the key is not registered. The option `default: d`
  defines the value `d` that should be returned instead of nil when the key
  is not yet set or has been deleted.
  """
  def get(key, opts \\ []) do
    case PaxosKV.Learner.get(key, opts) do
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
    case PaxosKV.Learner.get(key, opts) do
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
    case PaxosKV.Learner.get(key, opts) do
      {_value, %{node: node}} -> node
      _ -> Keyword.get(opts, :default)
    end
  end
end
