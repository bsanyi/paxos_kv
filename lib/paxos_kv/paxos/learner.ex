defmodule PaxosKV.Learner do
  @moduledoc """
  Implements the Learner role in the Paxos consensus algorithm.

  The Learner discovers and caches values that have been chosen by the cluster.
  It queries Acceptors to determine if a quorum has accepted the same value for
  a key, and attempts to complete interrupted consensus rounds when necessary.
  """

  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Cluster, Helpers, Proposer, Acceptor}
  require PaxosKV.Helpers.Msg, as: Msg

  ############################################
  ####  API

  @doc """
  It tries to figure out if a certain value has already been chosen for a
  certain `key`.

  In order to decide it first asks the local Learner if it has the answer in
  it's cache.  If not, the Learner asks the Acceptors about the accepted
  values, and checks if a quorum of Acceptors has the same value. If no quorum
  present, but there's a valid accepted value accepted by an acceptor, it means
  a basix paxos round was interrupted in the middle, so in that case it tries
  to finish the round.  If none of the above applies, it just returns
  `{:error, :not_found}`.
  """
  def get(key, opts) do
    {_bucket, name} = Helpers.name(opts, @name)
    no_quorum = Keyword.get(opts, :on_quorum, :return)

    case GenServer.call(name, {:get, key}) do
      {:ok, _value} = ok ->
        ok

      {:try, {value, meta}} ->
        Proposer.propose(key, value, Keyword.merge(opts, Map.to_list(meta)))

      {:error, :no_quorum} when no_quorum == :retry ->
        Helpers.random_backoff()
        get(key, opts)

      {:error, :no_quorum} when no_quorum == :fail ->
        throw(:no_quorum)

      {:error, :no_quorum} = error when no_quorum == :return ->
        error

      {:error, :not_found} = error ->
        error
    end
  end

  ############################################
  ####  PaxosKV API

  @doc """
  Signals all the Learner processes that an Acceptor on `node` in the `bucket`
  accepted an `{id, value}` pair under the key `key` in the PaxosKV key-value
  store. Acceptors trigger this event when they accept something.
  """
  def accepted(node, bucket, key, id, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:accepted, node, key, id, value})
  end

  @doc """
  Signals all the Learners that a certain `value` has been chosen by the
  cluster in the `bucket` under the key `key` in the PaxosKV key-value store.
  """
  def chosen(bucket, key, value) do
    name = Module.concat(bucket, @name)
    GenServer.abcast(name, {:chosen, key, value})
  end

  ############################################
  ####  Elixir/Erlang/OTP API

  def start_link(opts) do
    {bucket, name} = Helpers.name(opts, @name)
    GenServer.start_link(__MODULE__, bucket, name: name)
  end

  ############################################
  ####  GenServer callbacks

  use GenServer

  defmodule State do
    @moduledoc "State struct for the Paxos Learner process."
    defstruct bucket: nil, votes: %{}, pid_monitors: %{}, node_monitors: %{}, cache: %{}
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

  def handle_call({:get, key}, _from, state) do
    state = handle_priority_messages(state)
    cached_value = state.cache[key]

    cond do
      not Cluster.quorum?() ->
        {:reply, {:error, :no_quorum}, state}

      Map.has_key?(state.cache, key) and still_valid?(cached_value, state.cache) ->
        {:reply, {:ok, cached_value}, state}

      true ->
        state = %{state | cache: Map.delete(state.cache, key)}

        key
        |> Acceptor.info(state.bucket)
        |> Enum.filter(fn {_id, value} -> still_valid?(value, state.cache) end)
        |> case do
          [] ->
            {:reply, {:error, :not_found}, state}

          [{id, value} | _] = accepteds ->
            accepteds
            |> Enum.filter(&(&1 == {id, value}))
            |> Helpers.quorum?(Cluster.cluster_size())
            |> if do
              {:reply, {:ok, value}, state}
            else
              {:reply, {:try, value}, state}
            end
        end
    end
  end

  @impl true
  def handle_cast({:accepted, node, key, id, value}, state) do
    votes = Map.update(state.votes, key, %{node => {id, value}}, &Map.put(&1, node, {id, value}))
    new_state = %{state | votes: votes}

    if quorum_accepts?(votes[key], id, value, Cluster.cluster_size()) do
      handle_cast({:chosen, key, value}, new_state)
    else
      {:noreply, new_state}
    end
  end

  def handle_cast({:chosen, key, value}, state) do
    {pid_monitors, node_monitors} =
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

    {:noreply,
     %{
       state
       | pid_monitors: pid_monitors,
         node_monitors: node_monitors,
         cache: Map.put(state.cache, key, value)
     }}
  end

  @impl true
  def handle_info(Msg.monitor_down(ref: ref, type: :process, pid: _, reason: _), state) do
    if Map.has_key?(state.pid_monitors, ref) do
      key = state.pid_monitors[ref]
      votes = Map.delete(state.votes, key)
      cache = Map.delete(state.cache, key)
      pid_monitors = Map.delete(state.pid_monitors, ref)

      node_monitors =
        state.node_monitors
        |> Enum.flat_map(fn {node, keys} ->
          cond do
            keys == MapSet.new([key]) -> []
            key in keys -> [{node, MapSet.delete(keys, key)}]
            true -> [{node, keys}]
          end
        end)
        |> Enum.into(%{})

      {:noreply,
       %{
         state
         | votes: votes,
           pid_monitors: pid_monitors,
           node_monitors: node_monitors,
           cache: cache
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info(Msg.nodeup(_node), state) do
    {:noreply, state}
  end

  def handle_info(Msg.nodedown(node), state) do
    keys = Map.get(state.node_monitors, node, [])

    if keys != [] do
      votes = Map.reject(state.votes, fn {key, _} -> key in keys end)
      cache = Map.reject(state.cache, fn {key, _} -> key in keys end)
      node_monitors = Map.delete(state.node_monitors, node)
      pid_monitors = Map.reject(state.pid_monitors, fn {_key, value} -> value == 2 end)

      {:noreply,
       %{
         state
         | votes: votes,
           pid_monitors: pid_monitors,
           node_monitors: node_monitors,
           cache: cache
       }}
    else
      {:noreply, state}
    end
  end

  ############################################
  ####  Helpers

  defp still_valid?({_, %{key: key}} = value, cache) do
    if Helpers.still_valid?(value) and Map.has_key?(cache, key) do
      still_valid?(cache[key], cache)
    else
      false
    end
  end

  defp still_valid?(value, _cache), do: Helpers.still_valid?(value)

  defp quorum_accepts?(votes, id, value, n) do
    votes
    |> Map.values()
    |> Enum.filter(&(&1 == {id, value}))
    |> Helpers.quorum?(n)
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
