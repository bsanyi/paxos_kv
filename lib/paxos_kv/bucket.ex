defmodule PaxosKV.Bucket do
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
      start: {PaxosKV.Supervisor, :start_link, [[bucket: bucket]]},
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
