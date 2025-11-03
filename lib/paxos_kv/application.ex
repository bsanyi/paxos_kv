defmodule PaxosKV.Application do
  @moduledoc false

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
