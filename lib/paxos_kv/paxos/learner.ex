defmodule PaxosKV.Learner do
  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Cluster, Helpers, Proposer, Acceptor}
  require PaxosKV.Helpers.Msg, as: Msg

  ############################################
  ####  API

  def get(key, opts) do
    {_bucket, name} = Helpers.name(opts, @name)

    case GenServer.call(name, {:get, key}) do
      {:ok, value} ->
        value

      {:try, value} ->
        Proposer.propose(key, value, opts)

      :retry ->
        # Helpers.random_backoff()
        get(key, opts)

      {:error, :not_found} ->
        nil
    end
  end

  ############################################
  ####  PaxosKV API

  def accepted(node, bucket, key, id, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:accepted, node, key, id, value})
  end

  def chosen(bucket, key, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:chosen, key, value})
  end

  ############################################
  ####  Elixir/Erlang/OTP API

  def start_link(opts) do
    {_bucket, name} = Helpers.name(opts, @name)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  ############################################
  ####  GenServer callbacks

  use GenServer

  @impl true
  def init(_) do
    {:ok, {_votes = %{}, _pid_monitors = %{}, _node_monitors = %{}, _cache = %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:get, key}, _from, {votes, pid_monitors, node_monitors, cache} = state) do
    cached_value = cache[key]

    cond do
      not Cluster.quorum?() ->
        {:reply, :retry, state}

      Map.has_key?(cache, key) and Helpers.still_valid?(cached_value) ->
        {:reply, {:ok, cached_value}, state}

      true ->
        state = {votes, pid_monitors, node_monitors, Map.delete(cache, key)}

        case Acceptor.info(key) do
          [] ->
            {:reply, {:error, :not_found}, state}

          [value | _] = accepteds ->
            cond do
              not Helpers.still_valid?(value) ->
                {:reply, :retry, state}

              Helpers.quorum?(Enum.filter(accepteds, &(&1 == value)), Cluster.cluster_size()) ->
                {:reply, {:ok, value}, state}

              true ->
                {:reply, {:try, value}, state}
            end
        end
    end
  end

  @impl true
  def handle_cast({:accepted, node, key, id, value}, {votes, pid_monitors, node_monitors, cache}) do
    votes = Map.update(votes, key, %{node => {id, value}}, &Map.put(&1, node, {id, value}))

    if quorum?(votes[key], id, value, Cluster.cluster_size()) do
      handle_cast({:chosen, key, value}, {votes, pid_monitors, node_monitors, cache})
    else
      {:noreply, {votes, pid_monitors, node_monitors, cache}}
    end
  end

  def handle_cast({:chosen, key, value}, {votes, pid_monitors, node_monitors, cache}) do
    {new_pid_monitors, new_node_monitors} =
      case value do
        {_, %{pid: pid, node: node}} ->
          {Helpers.monitor_pid(pid, key, pid_monitors),
           Helpers.monitor_node(node, key, node_monitors)}

        {_, %{pid: pid}} ->
          {Helpers.monitor_pid(pid, key, pid_monitors), node_monitors}

        {_, %{node: node}} ->
          {pid_monitors, Helpers.monitor_node(node, key, node_monitors)}

        _ ->
          {pid_monitors, node_monitors}
      end

    {:noreply, {votes, new_pid_monitors, new_node_monitors, Map.put(cache, key, value)}}
  end

  @impl true
  def handle_info(
        Msg.monitor_down(ref: ref, type: :process, pid: _, reason: _),
        {votes, pid_monitors, node_monitors, cache}
      ) do
    if Map.has_key?(pid_monitors, ref) do
      new_votes = Map.delete(votes, pid_monitors[ref])
      new_pid_monitors = Map.delete(pid_monitors, ref)
      new_cache = Map.delete(cache, pid_monitors[ref])
      {:noreply, {new_votes, new_pid_monitors, node_monitors, new_cache}}
    else
      # should not happen
      {:noreply, {votes, pid_monitors, node_monitors, cache}}
    end
  end

  ############################################
  ####  Helpers

  defp quorum?(votes, id, value, n) do
    votes
    |> Map.values()
    |> Enum.filter(&(&1 == {id, value}))
    |> Helpers.quorum?(n)
  end
end
