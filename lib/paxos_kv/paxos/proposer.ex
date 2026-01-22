defmodule PaxosKV.Proposer do
  @moduledoc """
  Implements the Proposer role in the Paxos consensus algorithm.

  The Proposer initiates consensus rounds by proposing values to Acceptors. It
  coordinates the two-phase protocol (prepare and accept phases) to reach
  consensus on a value for a given key. When contention is detected, it falls
  back to a primary proposer to ensure liveness.
  """

  @name String.to_atom(List.last(Module.split(__MODULE__)))
  alias PaxosKV.{Helpers, Cluster, Acceptor, Learner}

  ###################################
  ####  API

  @doc """
  Asks the local Proposer to convince the cluster about a `value`.

  When it detects that there are other Proposer(s) trying to do the same, and
  the liveness property of Paxos is in danger, it falls back to a primary
  proposer (running on a node that is determined by the key) instead of the
  local service.

  ## Return values:

  - `{:ok, value}`: the `value` is the chosen (consensus) value for the `key`
  - `{:error, :no_quorum}`: there are't enough nodes participating in the cluster
  - `{:error, :invalid_value}`: the `pid` or `node` provided in `opts` is not alive
  """
  def propose(key, value, opts) do
    {_bucket, name} = Helpers.name(opts, @name)
    value = {value, opts |> Enum.into(%{}) |> Map.take([:pid, :node, :key, :until])}
    __propose(name, key, value)
  end

  defp __propose(name, key, value) do
    if Helpers.still_valid?(value) do
      case GenServer.call(name, {:propose, key, value}, _timeout = :infinity) do
        {:ok, _value} = response ->
          response

        {:error, :no_quorum} = response ->
          response

        {:error, :invalid_value} = response ->
          response

        {:error, :too_many_rounds} when is_atom(name) ->
          # redirect to the proposer on the primary node in order to serialize requests
          __propose({name, primary_node(key)}, key, value)

        {:error, :too_many_rounds} when is_tuple(name) ->
          # we already falled back to the primary proposer => all we need to do is just retry
          __propose(name, key, value)
      end
    else
      {:error, :invalid_value}
    end
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

  defmodule State do
    @moduledoc "State module for the Paxos Proposer process."
    defstruct [:id, :bucket, :redirects]
  end

  @impl true
  def init(bucket) do
    {:ok, %State{bucket: bucket, id: {0, Node.self()}, redirects: %{}}}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:propose, key, value}, from, state, try_round \\ 1) do
    state = check_redirects(state, key)

    {nodes, n} = Cluster.nodes_and_cluster_size()

    value =
      nodes
      |> check_quorum(n)
      |> Acceptor.prepare(state.bucket, state.id, key)
      |> check_quorum(n)
      |> check_nacks()
      |> accepted_value(value)

    nodes
    |> Acceptor.accept(state.bucket, state.id, key, value)
    |> check_quorum(n)
    |> check_nacks(1)
    |> check_invalid(n)

    Learner.chosen(state.bucket, key, value)

    {:reply, {:ok, value}, %{state | id: inc(state.id)}}
  catch
    :no_quorum ->
      {:reply, {:error, :no_quorum}, %{state | id: inc(state.id)}}

    :invalid_value ->
      {:reply, {:error, :invalid_value}, %{state | id: inc(state.id)}}

    :redirect ->
      {:reply, {:error, :too_many_rounds}, state}

    {:nack, id, try_increment} when try_round <= 3 ->
      handle_call({:propose, key, value}, from, %{state | id: inc(id)}, try_round + try_increment)

    {:nack, id, _} ->
      if primary_node(key) == Node.self() do
        handle_call({:propose, key, value}, from, %{state | id: inc(id)}, try_round)
      else
        t = System.system_time(:millisecond) + :timer.seconds(5)
        new_state = %{state | id: inc(id), redirects: Map.put(state.redirects, key, t)}
        {:reply, {:error, :too_many_rounds}, new_state}
      end
  end

  ###################################
  ####  Helpers

  # `primary_node(key)` choses a node for the `key`.
  #
  # When there are too many retries - that means more than one Proposer tries
  # to convince the cluster about a value, and there is a long race between
  # those Proposers -, this function provides a way to chose a single proposer
  # and fall back to that service instead of the local one. This function
  # returns the same node name on all nodes, so eventually every proposer will
  # fall back to the same primary proposer.
  defp primary_node(key) do
    nodes = Cluster.nodes()

    nodes
    |> Enum.sort()
    |> Enum.at(:erlang.phash2(key, length(nodes)))
  end

  # `check_quorum(list, n)` normally just returns the `list` when it is long
  # enugh. That is longer than `n / 2`. Otherwise it throws an exception. This
  # is useful because if it returns, we know the there are enough nodes,
  # responses, or whatever the list contains.
  defp check_quorum(list, n) do
    if 2 * length(list) > n do
      list
    else
      throw(:no_quorum)
    end
  end

  # `check_nacks/1,2` normally returns its first argument, which is supposed to
  # be a list of responses from the acceptors. The exceptional case is when the
  # list contains `{:nack, id}` type messages. In that case an exception is
  # thrown with the highest `id` in those tuples.
  defp check_nacks(responses, try_increment \\ 0) do
    responses
    |> Enum.filter(&match?({:nack, _}, &1))
    |> case do
      [] ->
        responses

      nacks ->
        {:nack, max_id} = Enum.max(nacks)
        throw({:nack, max_id, try_increment})
    end
  end

  # Checks if the quorum of the `responses` is `:invalid_value`. If so, it
  # throws an exception, otherwise just returns.
  defp check_invalid(responses, n) do
    responses
    |> Enum.filter(fn x -> x == :invalid_value end)
    |> Helpers.quorum?(n)
    |> Kernel.and(throw(:invalid_value))
  end

  # `accept_value(responses, orig_value)` is called with the list of Acceptor
  # responses from the prepare phase of Paxos. If there are `{:promise, id,
  # value}` responses in the list, this function returns the `value` with the
  # highes `id` among them. Otherwise it returns the `orig_value` argument.
  # This function is used to determine which value should a Proposer go on in
  # the accept phase of Paxos.
  defp accepted_value(responses, orig_value) do
    responses
    |> Enum.filter(&match?({:promise, _id, _value}, &1))
    |> case do
      [] ->
        orig_value

      accepteds ->
        {:promise, _id, value} = Enum.max(accepteds)
        value
    end
  end

  defp check_redirects(state, key) do
    t = state.redirects[key]

    cond do
      !!t and t <= System.system_time(:millisecond) ->
        throw(:redirect)

      !!t ->
        %{state | redirects: Map.delete(state.redirects, key)}

      true ->
        state
    end
  end

  defp inc({n, _node}), do: {n + 1, Node.self()}
end
