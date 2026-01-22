defmodule PaxosKV.Application do
  @moduledoc """
  OTP application module for PaxosKV.

  This module starts the application supervision tree, which includes the main
  bucket (containing Learner, Acceptor, and Proposer processes) and the cluster
  management GenServer.
  """

  use Application
  alias PaxosKV.{Cluster, PauseUntil, Helpers}

  @impl true
  def start(_type, _args) do
    cluster_size = Application.get_env(:paxos_kv, :cluster_size, _default = 3)

    children = [
      {PaxosKV.Bucket, bucket: PaxosKV},
      {PauseUntil, fn -> Helpers.wait_for_bucket(PaxosKV) end},
      {Cluster, cluster_size: cluster_size}
    ]

    opts = [strategy: :one_for_one, name: PaxosKV.RootSup]

    Supervisor.start_link(children, opts)
  end
end
