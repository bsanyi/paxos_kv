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
        {:reply, :invalid_value, new_state}

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

  @max_sync_keys 100

  def handle_info(Msg.nodeup(node), state) do
    # start_link ?
    Task.start(fn ->
      Helpers.wait_for(fn ->
        (Node.ping(node) == :pong) &&
          (:erpc.call(node, PaxosKV.Cluster, :ping, []) == :pong) &&
          is_pid(:erpc.call(node, Process, :whereis, [__MODULE__]))
      end)

      if not Enum.empty?(state.basic_states) do
        keys = Map.keys(state.basic_states)
        total = length(keys)
        count = ceil(total / @max_sync_keys)
        base = div(total, count)
        reminder = rem(total, count)
        chunk_sizes = List.duplicate(base + 1, reminder) ++ List.duplicate(base, count - reminder)
        sync_in_chunks(node, keys, state.basic_states, chunk_sizes)
      end
    end)

    {:noreply, state}
  end

  def handle_info(Msg.nodedown(node), state) do
    keys = Map.get(state.node_monitors, node, [])

    {:noreply, delete_keys(state, keys)}
  end

  def handle_info({:sync, basic_states}, state) do
    {:noreply, merge(state, basic_states)}
  end

  ###################################
  ####  Helpers

  defp reply(basic_state, key, state, message) do
    {:reply, message, add_basic_state(state, key, basic_state)}
  end

  defp multi_call(nodes, bucket, message) do
    name = Module.concat(bucket, @name)
    {responses, _bad_nodes} = GenServer.multi_call(nodes, name, message)
    Enum.map(responses, fn {_node, response} -> response end)
  end

  defp add_basic_state(state, key, basic_state) do
    %{state | basic_states: Map.put(state.basic_states, key, basic_state)}
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
    if !!basic_state and basic_state.accepted? and Helpers.still_valid?(value) do
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

  defp merge(state, basic_states) do
    merged_basic_states =
      Map.merge(state.basic_states, basic_states, fn _key, old, new ->
        {acc?, acc_id, acc_value} =
          max(
            {old.accepted?, old.accepted_id, old.accepted_value},
            {new.accepted?, new.accepted_id, new.accepted_value}
          )

        %BasicPaxosState{
          min_proposal: max(old.min_proposal, new.min_proposal),
          accepted?: acc?,
          accepted_id: acc_id,
          accepted_value: acc_value
        }
      end)

    new_state = %{state | basic_states: merged_basic_states}

    old_keys = MapSet.new(Map.keys(state.basic_states))
    new_keys = MapSet.new(Map.keys(basic_states))

    new_new_state =
      for key <- MapSet.difference(new_keys, old_keys), reduce: new_state do
        state ->
          basic_state = merged_basic_states[key]
          value = basic_state.accepted_value

          cond do
            basic_state.accepted? and still_valid?(value, merged_basic_states) ->
              Learner.accepted(Node.self(), state.bucket, key, basic_state.accepted_id, value)

              state
              |> add_pid_monitor(key, value)
              |> add_node_monitor(key, value)
              |> add_key_monitor(key, value)

            basic_state.accepted? ->
              delete_keys(state, [key])

            true ->
              state
          end
      end

    for key <- MapSet.intersection(new_keys, old_keys), reduce: new_new_state do
      state ->
        old_basic_state = state.basic_states[key]
        new_basic_state = merged_basic_states[key]

        old_value = old_basic_state.accepted_value
        value = new_basic_state.accepted_value

        cond do
          old_value == value ->
            state

          value.acceptd? and still_valid?(value, merged_basic_states) ->
            Learner.accepted(Node.self(), state.bucket, key, new_basic_state.accepted_id, value)

            state
            |> delete_keys([key])
            |> add_basic_state(key, new_basic_state)
            |> add_pid_monitor(key, value)
            |> add_node_monitor(key, value)
            |> add_key_monitor(key, value)

          value.accepted? ->
            delete_keys(state, [key])

          true ->
            state
        end
    end
  end

  defp handle_priority_messages(state) do
    receive do
      Msg.monitor_down(ref: _, type: :process, pid: _, reason: _) = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)

      Msg.nodedown(_node) = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)

      Msg.nodeup(_node) = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)

      {:sync, _basic_states} = msg ->
        {:noreply, new_state} = handle_info(msg, state)
        handle_priority_messages(new_state)

    after
      0 -> state
    end
  end

  defp sync_in_chunks(_node, _keys, _map, []), do: nil

  defp sync_in_chunks(node, keys, map, [chunk_size | rest_of_sizes]) do
    {chunk_keys, rest_of_keys} = Enum.split(keys, chunk_size)
    send({__MODULE__, node}, {:sync, Map.take(map, chunk_keys)})
    sync_in_chunks(node, rest_of_keys, map, rest_of_sizes)
  end
end
