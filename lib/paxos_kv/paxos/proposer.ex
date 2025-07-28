defmodule PaxosKV.Proposer do
  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Helpers, Cluster, Learner}

  ###################################
  ####  API

  def propose(key, value, opts) do
    {_bucket, name} = Helpers.name(opts, @name)
    val = {value, opts |> Enum.into(%{}) |> Map.take([:pid, :node])}
    _propose(name, key, val, 0)
  end

  ###################################
  ####  Elixir/Erlang/OTP API

  def start_link(opts) do
    {bucket, name} = Helpers.name(opts, @name)
    GenServer.start_link(__MODULE__, bucket, name: name)
  end

  ###################################
  ####  GenServer implementation

  use GenServer

  @impl true
  def init(bucket) do
    {:ok, {bucket, {0, Node.self()}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:propose, key, value}, _from, {bucket, id}) do
    {nodes, n} = Cluster.nodes_and_cluster_size()

    unless Helpers.quorum?(nodes, n), do: throw(:no_quorum)

    {id, value} =
      value
      |> phase_one(id, bucket, key, n, nodes)
      |> phase_two(id, bucket, key, n, nodes)

    Learner.chosen(bucket, key, value)

    {:reply, {:ok, value}, {bucket, inc(id)}}
  catch
    :no_quorum ->
      {:reply, {:error, :no_quorum}, {bucket, inc(id)}}

    {:retry, max_id} ->
      {:reply, {:error, :retry}, {bucket, inc(max_id)}}
  end

  ###################################
  ####  Helpers

  defp _propose(name, key, value, try_count) do
    if Helpers.still_valid?(value) do
      proposer = if try_count < 2, do: name, else: {name, primary_proposer(key)}

      case GenServer.call(proposer, {:propose, key, value}) do
        {:ok, value} ->
          value

        {:error, :no_quorum} ->
          Helpers.random_backoff()
          _propose(name, key, value, try_count)

        {:error, :retry} when try_count == 0 ->
          _propose(name, key, value, try_count + 1)

        {:error, :retry} ->
          Helpers.random_backoff()
          _propose(name, key, value, try_count + 1)
      end
    else
      nil
    end
  end

  defp primary_proposer(key) do
    {nodes, n} = Cluster.nodes_and_cluster_size()

    nodes
    |> Enum.sort()
    |> Enum.at(:erlang.phash2(key, n))
  end

  defp inc({n, _node}), do: {n + 1, Node.self()}

  defp phase_one(value, id, bucket, key, n, nodes) do
    case multi_call(nodes, bucket, n, {:prepare, key, {id, Node.self()}}) do
      {:ok, value2} -> value2
      :ok -> value
    end
  end

  defp phase_two(value, id, bucket, key, n, nodes) do
    case multi_call(nodes, bucket, n, {:accept, key, {id, Node.self()}, value}) do
      {:accepted, max_id} when max_id > id ->
        throw({:retry, max_id})

      {:accepted, _max_id} ->
        {id, value}
    end
  end

  defp multi_call(nodes, bucket, n, message) do
    name = Module.concat(bucket, Acceptor)

    responses =
      nodes
      |> GenServer.multi_call(name, message, 5_000)
      |> elem(0)
      |> Enum.map(fn {_node, reply} -> reply end)

    stat = stat(responses)

    cond do
      not Helpers.quorum?(responses, n) ->
        throw(:no_quorum)

      stat.nack? ->
        throw({:retry, Enum.max(stat.nacks)})

      stat.promise? and stat.value? ->
        value = stat.accepted |> Enum.max() |> elem(1)
        {:ok, value}

      stat.promise? ->
        :ok

      stat.accepted? ->
        {:accepted, Enum.max(stat.ids)}
    end
  end

  defp stat(responses) do
    for resp <- responses,
        reduce: %{
          ids: [],
          promise?: false,
          value?: false,
          nacks: [],
          nack?: false,
          accepted: [],
          accepted?: false
        } do
      state ->
        case resp do
          :promise ->
            %{state | promise?: true}

          {:promise, {id, _node}, value} ->
            %{
              state
              | promise?: true,
                value?: true,
                accepted: [{id, value} | state.accepted],
                ids: [id | state.ids]
            }

          {:nack, {id, _node}} ->
            %{state | nack?: true, nacks: [id | state.nacks]}

          {:accepted, {id, _node}} ->
            %{state | accepted?: true, ids: [id | state.ids]}
        end
    end
  end
end
