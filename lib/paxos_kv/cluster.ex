defmodule PaxosKV.Cluster do
  @moduledoc """
  Manages the cluster state and node membership.

  This module tracks which nodes are part of the distributed cluster, monitors
  node connections, and maintains the configured cluster size. It provides
  functions to query the current cluster state and check if a quorum is present.
  """

  require PaxosKV.Helpers.Msg, as: Msg
  alias PaxosKV.Helpers

  @nodes_key Module.concat(__MODULE__, Nodes)
  @cluster_size_key Module.concat(__MODULE__, ClusterSize)

  ############################################
  ####  API

  @doc """
  Returns the list of currently connected nodes in the cluster.

  ## Examples

      iex> PaxosKV.Cluster.nodes()
      [:node1@localhost, :node2@localhost]

  """
  def nodes do
    :persistent_term.get(@nodes_key, [])
  end

  @doc """
  Returns the configured cluster size.

  This is the total number of nodes expected to participate in the cluster,
  not necessarily the number of currently connected nodes.

  ## Examples

      iex> PaxosKV.Cluster.cluster_size()
      3

  """
  def cluster_size do
    {_time, _node, size} = :persistent_term.get(@cluster_size_key)
    size
  end

  @doc """
  Returns both the connected nodes list and the cluster size as a tuple.

  ## Examples

      iex> PaxosKV.Cluster.nodes_and_cluster_size()
      {[:node1@localhost, :node2@localhost], 3}

  """
  def nodes_and_cluster_size do
    {nodes(), cluster_size()}
  end

  @doc """
  Checks if the cluster currently has a quorum.

  A quorum exists when more than half of the configured cluster size nodes
  are connected.

  ## Examples

      iex> PaxosKV.Cluster.quorum?()
      true

  """
  def quorum? do
    Helpers.quorum?(nodes(), cluster_size())
  end

  @doc """
  Dynamically resizes the cluster to a new size.

  Attempts to update the cluster size on all nodes. Returns `:ok` if all
  nodes successfully updated to the new size, `:not_in_sync` if nodes
  disagreed, or `{:error, reason}` if the operation failed.

  ## Examples

      iex> PaxosKV.Cluster.resize_cluster(5)
      :ok

  """
  def resize_cluster(new_size) do
    t = System.system_time()
    node = Node.self()

    case GenServer.multi_call(__MODULE__, {:resize_cluster, {t, node, new_size}}) do
      {responses, []} ->
        if Enum.all?(responses, &match?({_node, ^new_size}, &1)) do
          :ok
        else
          :not_in_sync
        end

      error ->
        {:error, error}
    end

    # TODO:
    #  - try to signal if it was successful
    #  - check if
    #    - we have a quorum before resizing
    #    - quorum is kept after resizing
    #    - new size isn't below the number of nodes currently in the cluster
  end

  @doc """
  Subscribes the caller process or the spcified pid for `:quorum_reached` and
  `:quorum_lost` cluster events. The events are delivered as standard erlang
  messages.
  """
  def subscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc """
  The opposite of `subscribe/0,1`. It removes the given pid from
  the list of subscribed processes.
  """
  def unsubscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  after
    Helpers.flush_messages([:quorum_reached, :quorum_lost])
  end

  ############################################
  ####  Elixir/Erlang/OTP API

  def start_link(opts) do
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    GenServer.start_link(__MODULE__, cluster_size, name: __MODULE__)
  end

  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  ############################################
  ####  GenServer implmentation

  use GenServer

  require Logger

  @impl true
  def init(cluster_size) do
    if Node.alive?() do
      :net_kernel.monitor_nodes(true)

      update_size({0, Node.self(), cluster_size})

      for node <- Node.list([:visible, :this]) do
        send(self(), Msg.nodeup(node))
      end

      {:ok, []}
    else
      Logger.warning("This node is not started in distributed mode.")
      :ignore
    end
  end

  @impl true
  def handle_continue({:wait_for, bucket}, state) do
    Helpers.wait_for_bucket(bucket)
    {:noreply, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    notify(pid, quorum?())
    ref = Process.monitor(pid)
    {:reply, :ok, Enum.uniq([{ref, pid} | state])}
  end

  def handle_call({:unsubscribe, pid}, _from, state) when is_pid(pid) do
    for {ref, p} <- state, p == pid do
      Process.demonitor(ref, [:flush])
    end

    {:noreply, new_state} =
      handle_info(Msg.monitor_down(ref: nil, type: :process, pid: pid, reason: nil), state)

    {:reply, :ok, new_state}
  end

  def handle_call({:resize_cluster, {_time, _node, new_size} = new}, _from, state) do
    {nodes, n} = nodes_and_cluster_size()

    if update_size(new) == :updated do
      publish("Cluster resize", nodes, nodes, n, new_size, state)
      GenServer.abcast(__MODULE__, {:resize_cluster, new})
    end

    {:reply, cluster_size(), state}
  end

  @impl true
  def handle_cast({:resize_cluster, {_time, _node, new_size} = new}, state) do
    {nodes, n} = nodes_and_cluster_size()

    if update_size(new) == :updated do
      publish("Cluster resize", nodes, nodes, n, new_size, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(Msg.nodeup(node), state) do
    Task.async(__MODULE__, :sync_with_node, [node])
    Logger.debug("[#{Node.self()}] Node #{node} connected.", ansi_color: :faint)
    {:noreply, state}
  end

  def handle_info(Msg.nodedown(node), state) do
    {nodes, n} = nodes_and_cluster_size()
    new_nodes = Enum.reject(nodes, &(&1 == node))
    persist(new_nodes)
    publish("Node #{node} is down.", nodes, new_nodes, n, n, state)
    {:noreply, state}
  end

  def handle_info(Msg.task_reply(ref: ref, reply: node), state)
      when is_reference(ref) and is_atom(node) do
    Process.demonitor(ref, [:flush])
    {nodes, n} = nodes_and_cluster_size()
    new_nodes = Enum.uniq([node | nodes])
    persist(new_nodes)
    publish("Node #{node} is up.", nodes, new_nodes, n, n, state)
    {:noreply, state}
  end

  def handle_info(Msg.monitor_down(ref: ref, type: :process, pid: pid, reason: _), state) do
    new_state = Enum.reject(state, fn {r, p} -> r == ref or p == pid end)
    {:noreply, new_state}
  end

  ############################################
  ####  Helpers

  def sync_with_node(node) do
    Helpers.wait_for(fn -> GenServer.call({__MODULE__, node}, :ping) == :pong end)
    GenServer.cast({__MODULE__, node}, {:resize_cluster, :persistent_term.get(@cluster_size_key)})
    node
  end

  defp persist(nodes) do
    :persistent_term.put(@nodes_key, Enum.sort(nodes))
  end

  defp update_size(new) do
    current = {_, _, old} = :persistent_term.get(@cluster_size_key, {-1, nil, nil})

    if new > current do
      :persistent_term.put(@cluster_size_key, new)
      if old != new, do: :updated
    end
  end

  defp notify(pid, true = _quorum?), do: send(pid, :quorum_reached)
  defp notify(pid, false = _quorum?), do: send(pid, :quorum_lost)

  defp publish(msg, old_nodes, new_nodes, old_cluster_size, new_cluster_size, subscribers) do
    old_quorum? = Helpers.quorum?(old_nodes, old_cluster_size)
    new_quorum? = Helpers.quorum?(new_nodes, new_cluster_size)
    quorum = if new_quorum?, do: "quorum:yes", else: "quorum:no"

    n = length(new_nodes)
    node_stat = "cluster:#{n}/#{new_cluster_size}"

    if old_cluster_size != new_cluster_size do
      Logger.info([
        "[#{Node.self()}] Cluster size changed ",
        "from #{old_cluster_size} to #{new_cluster_size} ",
        "[#{node_stat}] [#{quorum}]"
      ])
    else
      Logger.info("[#{Node.self()}] #{msg} [#{node_stat}] [#{quorum}]")
    end

    cond do
      old_quorum? and not new_quorum? ->
        for {_ref, pid} <- subscribers, do: notify(pid, false)
        Logger.warning("[#{Node.self()}] Quorum lost. [#{node_stat}]")

      not old_quorum? and new_quorum? ->
        for {_ref, pid} <- subscribers, do: notify(pid, true)
        Logger.info("[#{Node.self()}] Quorum reached. [#{node_stat}]")

      n > new_cluster_size ->
        Logger.warning("[#{Node.self()}] More nodes than configured cluster size. [#{node_stat}]")

      true ->
        nil
    end
  end
end
