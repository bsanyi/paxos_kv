defmodule PaxosKV.Acceptor do
  @name String.to_atom(List.last(Module.split(__MODULE__)))

  alias PaxosKV.{Cluster, Helpers, Learner}
  require PaxosKV.Helpers.Msg, as: Msg

  ###################################
  ####  API

  def prepare(nodes, bucket, id, key) do
    multi_call(nodes, bucket, {:prepare, key, id})
  end

  def accept(nodes, bucket, id, key, value) do
    multi_call(nodes, bucket, {:accept, key, id, value})
  end

  def keys(nodes, bucket) do
    multi_call(nodes, bucket, :keys)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Collects a list of accepted `{id, value}` pairs from the acceptors.
  """
  def info(key, bucket) do
    Cluster.nodes()
    |> multi_call(bucket, {:info, key})
    |> Enum.filter(& &1)
    |> Enum.sort(:desc)
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

  defmodule BasicPaxosState do
    @moduledoc false

    defstruct min_proposal: 0,
              accepted?: false,
              accepted_id: nil,
              accepted_value: nil
  end

  defmodule State do
    @moduledoc false

    defstruct bucket: nil,
              pid_monitors: %{},
              node_monitors: %{},
              keys: %{},
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
    state = handle_priority_messages(state)
    basic_state = Map.get(state.basic_states, key, %BasicPaxosState{})

    cond do
      id <= basic_state.min_proposal ->
        {:reply, {:nack, basic_state.min_proposal}, state}

      basic_state.accepted? and still_valid?(basic_state.accepted_value, state.basic_states) ->
        %{basic_state | min_proposal: id}
        |> reply(key, state, {:promise, basic_state.accepted_id, basic_state.accepted_value})

      basic_state.accepted? ->
        new_state = delete_keys(state, [key])

        %BasicPaxosState{min_proposal: id}
        |> reply(key, new_state, :promise)

      true ->
        %BasicPaxosState{min_proposal: id}
        |> reply(key, state, :promise)
    end
  end

  def handle_call({:accept, key, id, value}, _from, state) do
    state = handle_priority_messages(state)
    basic_state = Map.get(state.basic_states, key, %BasicPaxosState{})

    cond do
      id < basic_state.min_proposal ->
        {:reply, {:nack, basic_state.min_proposal}, state}

      not still_valid?(value, state.basic_states) ->
        new_state = delete_keys(state, [key])
        {:reply, {:nack, id}, new_state}

      true ->
        Learner.accepted(Node.self(), state.bucket, key, id, value)

        new_state =
          state
          |> add_pid_monitor(key, value)
          |> add_node_monitor(key, value)
          |> add_key_monitor(key, value)

        basic_state
        |> Map.merge(%{accepted?: true, accepted_id: id, accepted_value: value, min_proposal: id})
        |> reply(key, new_state, :accepted)
    end
  end

  def handle_call(:keys, _from, state) do
    # state = handle_priority_messages(state)
    {:reply, Map.keys(state.basic_states), state}
  end

  def handle_call({:info, key}, _from, state) do
    state = handle_priority_messages(state)

    case Map.get(state.basic_states, key) do
      %BasicPaxosState{accepted?: true} = basic_state ->
        {:reply, {basic_state.accepted_id, basic_state.accepted_value}, state}

      _ ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_info(Msg.monitor_down(ref: ref, type: :process, pid: _, reason: _), state) do
    if Map.has_key?(state.pid_monitors, ref) do
      key = state.pid_monitors[ref]

      {:noreply, delete_keys(state, [key])}
    else
      # should not happen
      {:noreply, state}
    end
  end

  def handle_info(Msg.nodeup(_node), state) do
    {:noreply, state}
  end

  def handle_info(Msg.nodedown(node), state) do
    keys = Map.get(state.node_monitors, node, [])

    {:noreply, delete_keys(state, keys)}
  end

  ###################################
  ####  Helpers

  defp reply(basic_state, key, state, message) do
    {:reply, message, %{state | basic_states: Map.put(state.basic_states, key, basic_state)}}
  end

  defp multi_call(nodes, bucket, message) do
    name = Module.concat(bucket, @name)
    {responses, _bad_nodes} = GenServer.multi_call(nodes, name, message)
    Enum.map(responses, fn {_node, response} -> response end)
  end

  defp add_pid_monitor(state, key, {_value, meta}) do
    if pid = Map.get(meta, :pid) do
      %{state | pid_monitors: Helpers.monitor_pid(pid, key, state.pid_monitors)}
    else
      state
    end
  end

  defp add_node_monitor(state, key, {_value, meta}) do
    if node = Map.get(meta, :node) do
      %{state | node_monitors: Helpers.monitor_node(node, key, state.node_monitors)}
    else
      state
    end
  end

  defp add_key_monitor(state, key, {_value, meta}) do
    xkey = Map.get(meta, :key)

    if xkey && key != xkey do
      %{state | keys: Helpers.monitor_key(xkey, key, state.keys)}
    else
      state
    end
  end

  defp still_valid?({_, %{key: key}} = value, basic_states) do
    basic_state = basic_states[key]
    if Helpers.still_valid?(value) and !!basic_state and basic_state.accepted? do
      still_valid?(basic_state.accepted_value, basic_states)
    else
      false
    end
  end

  defp still_valid?(value, _basic_states), do: Helpers.still_valid?(value)

  defp delete_keys(state, []), do: state

  defp delete_keys(state, keys) do
    basic_states = Map.drop(state.basic_states, keys)

    for {ref, key} <- state.pid_monitors, key in keys do
      Process.demonitor(ref, [:flush])
    end

    pid_monitors = Map.reject(state.pid_monitors, fn {_ref, key} -> key in keys end)

    node_monitors =
      for {k, v} <- state.node_monitors do
        {k, Enum.reject(v, &(&1 in keys))}
      end
      |> Enum.reject(&match?({_, []}, &1))
      |> Enum.into(%{})

    {key_refs, new_keys} = Map.split(state.keys, keys)

    new_state =
      %{
        state
        | pid_monitors: pid_monitors,
          node_monitors: node_monitors,
          keys: new_keys,
          basic_states: basic_states
      }

    delete_keys(new_state, List.flatten(Map.values(key_refs)))
  end

  defp handle_priority_messages(state) do
    receive do
      Msg.monitor_down(ref: _, type: :process, pid: _, reason: _) = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)

      Msg.nodedown(_node) = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)
    after
      0 -> state
    end
  end
end
