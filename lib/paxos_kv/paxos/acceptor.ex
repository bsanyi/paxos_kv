defmodule PaxosKV.Acceptor do
  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Cluster, Helpers, Learner}

  ###################################
  ####  API

  def info(key) do
    Cluster.nodes()
    |> GenServer.multi_call(__MODULE__, {:info, key})
    |> elem(0)
    |> Enum.sort(:desc)
    |> Enum.flat_map(fn
      {_node, {_id, value}} -> [value]
      {_node, nil} -> []
    end)
  end

  ###################################
  ####  Elixir/Erlang/OTP API

  require Helpers

  def start_link(opts) do
    {bucket, name} = Helpers.name(opts, @name)
    GenServer.start_link(__MODULE__, bucket, name: name)
  end

  ###################################
  ####  GenServer implementation

  use GenServer

  defmodule BasicPaxosState do
    defstruct min_proposal: 0,
              accepted?: false,
              accepted_id: nil,
              accepted_value: nil
  end

  @impl true
  def init(bucket) do
    {:ok, {bucket, %{}, %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:prepare, key, id}, _from, {bucket, monitors, states}) do
    state = Map.get(states, key, %BasicPaxosState{})

    cond do
      id > state.min_proposal and state.accepted? ->
        state
        |> Map.put(:min_proposal, id)
        |> reply(bucket, key, monitors, states, {:promise, state.accepted_id, state.accepted_value})

      id > state.min_proposal ->
        state
        |> Map.put(:min_proposal, id)
        |> reply(bucket, key, monitors, states, :promise)

      true ->
        reply(state, bucket, key, monitors, states, {:nack, state.min_proposal})
    end
  end

  def handle_call({:accept, key, id, value}, _from, {bucket, monitors, states}) do
    state = Map.get(states, key, %BasicPaxosState{})

    if id >= state.min_proposal do
      Learner.accepted(Node.self(), bucket, key, id, value)

      new_monitors =
        case value do
          {_, %{pid: pid}} -> Helpers.monitor(pid, key, monitors)
          _ -> monitors
        end

      state
      |> Map.merge(%{accepted?: true, accepted_id: id, accepted_value: value, min_proposal: id})
      |> reply(bucket, key, new_monitors, states, {:accepted, id})
    else
      reply(state, bucket, key, monitors, states, {:accepted, state.min_proposal})
    end
  end

  def handle_call({:info, key}, _from, {bucket, monitors, states}) do
    case Map.get(states, key) do
      %BasicPaxosState{accepted?: true} = state ->
        {:reply, {state.accepted_id, state.accepted_value}, {bucket, monitors, states}}

      _ ->
        {:reply, nil, {bucket, monitors, states}}
    end
  end

  @impl true
  def handle_info(Helpers.monitor_down(ref: ref, type: :process, pid: _, reason: _), {bucket, monitors, states}) do
    if Map.has_key?(monitors, ref) do
      new_monitors = Map.delete(monitors, ref)
      new_states = Map.delete(states, monitors[ref])
      {:noreply, {bucket, new_monitors, new_states}}
    else
      # should not happen
      {:noreply, {bucket, monitors, states}}
    end
  end

  ###################################
  ####  Helpers

  defp reply(state, bucket, key, monitors, states, message) do
    {:reply, message, {bucket, monitors, Map.put(states, key, state)}}
  end
end
