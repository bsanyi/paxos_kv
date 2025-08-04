defmodule PaxosKV do
  @moduledoc File.read!("README.md")

  def put(key, value, opts \\ []) do
    case PaxosKV.Proposer.propose(key, value, opts) do
      {value, _meta} -> value
    end
  end

  def get(key, opts \\ []) do
    case PaxosKV.Learner.get(key, opts) do
      {value, _meta} -> value
      _ -> Keyword.get(opts, :default)
    end
  end

  def pid(key, opts \\ []) do
    case PaxosKV.Learner.get(key, opts) do
      {_value, %{pid: pid}} -> pid
      _ -> Keyword.get(opts, :default)
    end
  end

  def node(key, opts \\ []) do
    case PaxosKV.Learner.get(key, opts) do
      {_value, %{node: node}} -> node
      _ -> Keyword.get(opts, :default)
    end
  end
end
