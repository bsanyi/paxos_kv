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

  defmodule State do
    defstruct bucket: nil,
              pid_monitors: %{},
              node_monitors: %{},
              basic_states: %{}
  end

  @impl true
  def init(bucket) do
    :net_kernel.monitor_nodes(true)
    {:ok, %State{bucket: bucket}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:prepare, key, id}, _from, state) do
    basic_state = Map.get(state.basic_states, key, %BasicPaxosState{})

    cond do
      id > basic_state.min_proposal and basic_state.accepted? ->
        basic_state
        |> Map.put(:min_proposal, id)
        |> reply(key, state, {:promise, basic_state.accepted_id, basic_state.accepted_value})

      id > basic_state.min_proposal ->
        basic_state
        |> Map.put(:min_proposal, id)
        |> reply(key, state, :promise)

      true ->
        {:reply, {:nack, basic_state.min_proposal}, state}
    end
  end

  def handle_call({:accept, key, id, value}, _from, state) do
    basic_state = Map.get(state.basic_states, key, %BasicPaxosState{})

    cond do
      id < basic_state.min_proposal ->
        {:reply, {:accepted, basic_state.min_proposal}, state}

      id >= basic_state.min_proposal and not Helpers.still_valid?(value) ->
        {:reply, {:nack, id}, %{state | basic_states: Map.delete(state.basic_states, key)}}

      id >= basic_state.min_proposal ->
        Learner.accepted(Node.self(), state.bucket, key, id, value)

        {new_pid_monitors, new_node_monitors} =
          case value do
            {_, %{pid: pid, node: node}} ->
              {Helpers.monitor_pid(pid, key, state.pid_monitors),
               Helpers.monitor_node(node, key, state.node_monitors)}

            {_, %{pid: pid}} ->
              {Helpers.monitor_pid(pid, key, state.pid_monitors), state.node_monitors}

            {_, %{node: node}} ->
              {state.pid_monitors, Helpers.monitor_node(node, key, state.node_monitors)}

            _ ->
              {state.pid_monitors, state.node_monitors}
          end

        basic_state
        |> Map.merge(%{accepted?: true, accepted_id: id, accepted_value: value, min_proposal: id})
        |> reply(
          key,
          Map.merge(state, %{pid_monitors: new_pid_monitors, node_monitors: new_node_monitors}),
          {:accepted, id}
        )
    end
  end

  def handle_call({:info, key}, _from, state) do
    case Map.get(state.basic_states, key) do
      %BasicPaxosState{accepted?: true} = basic_state ->
        {:reply, {basic_state.accepted_id, basic_state.accepted_value}, state}

      _ ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_info(Helpers.monitor_down(ref: ref, type: :process, pid: _, reason: _), state) do
    if Map.has_key?(state.pid_monitors, ref) do
      key = state.pid_monitors[ref]

      new_pid_monitors = Map.delete(state.pid_monitors, ref)
      new_basic_states = Map.delete(state.basic_states, key)

      new_node_monitors =
        for {k, v} <- state.node_monitors, into: %{} do
          {k, Enum.filter(v, &(&1 != key))}
        end

      {:noreply,
       %{
         state
         | pid_monitors: new_pid_monitors,
           node_monitors: new_node_monitors,
           basic_states: new_basic_states
       }}
    else
      # should not happen
      {:noreply, state}
    end
  end

  def handle_info(Helpers.nodedown(node), state) do
    keys = Map.get(state.node_monitors, node, [])

    new_pid_monitors = Map.reject(state.pid_monitors, fn {_key, value} -> value in keys end)
    new_basic_states = Map.drop(state.basic_states, keys)

    {:noreply,
     %{
       state
       | pid_monitors: new_pid_monitors,
         node_monitors: Map.delete(state.node_monitors, node),
         basic_states: new_basic_states
     }}
  end

  def handle_info(Helpers.nodeup(_node), state) do
    {:noreply, state}
  end

  ###################################
  ####  Helpers

  defp reply(basic_state, key, state, message) do
    {:reply, message, %{state | basic_states: Map.put(state.basic_states, key, basic_state)}}
  end
end
