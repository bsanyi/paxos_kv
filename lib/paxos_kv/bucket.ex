defmodule PaxosKV.Bucket do
  @moduledoc """
  Supervisor for a bucket's Paxos processes.

  A bucket contains the three core Paxos components: Learner, Acceptor, and
  Proposer. This supervisor manages these processes and ensures they are
  properly supervised and restarted if needed.
  """

  use Supervisor

  def start_link(opts) do
    bucket = Keyword.get(opts, :bucket, PaxosKV)
    name = Keyword.get(opts, :name, bucket)
    Supervisor.start_link(__MODULE__, bucket, name: name)
  end

  def child_spec(opts) do
    bucket = Keyword.get(opts, :bucket, PaxosKV)

    %{
      id: bucket,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(bucket) do
    children = [
      {PaxosKV.Learner, bucket: bucket},
      {PaxosKV.Acceptor, bucket: bucket},
      {PaxosKV.Proposer, bucket: bucket}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
