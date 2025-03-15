defmodule PaxosKV.Learner do
  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Cluster, Helpers, Proposer, Acceptor}

  ############################################
  ####  API

  def get(key, opts) do
    {_bucket, name} = Helpers.name(opts, @name)

    case GenServer.call(name, {:get, key}) do
      {:ok, value} -> value
      {:try, value} -> Proposer.propose(key, value, opts)
      {:error, :not_found} -> Keyword.get(opts, :default)
    end
  end

  ############################################
  ####  PaxosKV API

  def accepted(node, bucket, key, id, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:accepted, node, key, id, value})
  end

  def choosen(bucket, key, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:choosen, key, value})
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
  require Helpers

  @impl true
  def init(_) do
    {:ok, {%{}, %{}, %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:get, key}, _from, {_votes, _monitors, cache} = state) do
    if Map.has_key?(cache, key) do
      {:reply, {:ok, cache[key]}, state}
    else
      case Acceptor.info(key) do
        [value | _] -> {:reply, {:try, value}, state}
        [] -> {:reply, {:error, :not_found}, state}
      end
    end
  end

  @impl true
  def handle_cast({:accepted, node, key, id, value}, {votes, monitors, cache}) do
    votes = Map.update(votes, key, %{node => {id, value}}, &Map.put(&1, node, {id, value}))

    if quorum?(votes[key], id, value, Cluster.cluster_size()) do
      handle_cast({:choosen, key, value}, {votes, monitors, cache})
    else
      {:noreply, {votes, monitors, cache}}
    end
  end

  def handle_cast({:choosen, key, {_, %{pid: pid}} = value}, {votes, monitors, cache}) do
    new_monitors = Helpers.monitor(pid, key, monitors)
    {:noreply, {votes, new_monitors, Map.put(cache, key, value)}}
  end

  def handle_cast({:choosen, key, value}, {votes, monitors, cache}) do
    {:noreply, {votes, monitors, Map.put(cache, key, value)}}
  end

  @impl true
  def handle_info(Helpers.monitor_down(ref: ref, type: :process, pid: _, reason: _), {votes, monitors, cache}) do
    if Map.has_key?(monitors, ref) do
      new_votes = Map.delete(votes, monitors[ref])
      new_monitors = Map.delete(monitors, ref)
      new_cache = Map.delete(cache, monitors[ref])
      {:noreply, {new_votes, new_monitors, new_cache}}
    else
      # should not happen
      {:noreply, {votes, monitors, cache}}
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
