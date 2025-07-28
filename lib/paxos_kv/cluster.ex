defmodule PaxosKV.Cluster do
  require PaxosKV.Helpers, as: Helpers

  @nodes_key Module.concat(__MODULE__, Nodes)
  @cluster_size_key Module.concat(__MODULE__, ClusterSize)

  ############################################
  ####  API

  def nodes do
    :persistent_term.get(@nodes_key, [])
  end

  def cluster_size do
    {_time, _node, size} = :persistent_term.get(@cluster_size_key)
    size
  end

  def nodes_and_cluster_size do
    {nodes(), cluster_size()}
  end

  def quorum? do
    Helpers.quorum?(nodes(), cluster_size())
  end

  def resize_cluster(new_size) do
    t = System.system_time()
    node = Node.self()
    GenServer.multi_call(__MODULE__, {:resize_cluster, {t, node, new_size}})
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
        send(self(), Helpers.nodeup(node))
      end

      {:ok, nil}
    else
      Logger.error("This node is not started in distributed mode.")
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

  def handle_call({:resize_cluster, {_time, _node, new_size} = new}, _from, state) do
    {nodes, n} = nodes_and_cluster_size()

    if update_size(new) == :updated do
      log("Cluster resize", nodes, nodes, n, new_size)
      GenServer.abcast(__MODULE__, {:resize_cluster, new})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:resize_cluster, {_time, _node, new_size} = new}, state) do
    {nodes, n} = nodes_and_cluster_size()

    if update_size(new) == :updated do
      log("Cluster resize", nodes, nodes, n, new_size)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(Helpers.nodeup(node), state) do
    Task.async(__MODULE__, :sync_with_node, [node])
    Logger.debug("[#{Node.self()}] Node #{node} connected.", ansi_color: :faint)
    {:noreply, state}
  end

  def handle_info(Helpers.nodedown(node), state) do
    {nodes, n} = nodes_and_cluster_size()
    new_nodes = Enum.reject(nodes, &(&1 == node))
    persist(new_nodes)
    log("Node #{node} is down.", nodes, new_nodes, n, n)
    {:noreply, state}
  end

  def handle_info(Helpers.task_reply(ref: ref, reply: node), state)
      when is_reference(ref) and is_atom(node) do
    Process.demonitor(ref, [:flush])
    {nodes, n} = nodes_and_cluster_size()
    new_nodes = Enum.uniq([node | nodes])
    persist(new_nodes)
    log("Node #{node} is up.", nodes, new_nodes, n, n)
    {:noreply, state}
  end

  ############################################
  ####  Helpers

  def sync_with_node(node) do
    Helpers.wait_for(fn -> GenServer.call({__MODULE__, node}, :ping) == :pong end)
    GenServer.cast({__MODULE__, node}, {:resize_cluster, :persistent_term.get(@cluster_size_key)})
    node
  end

  defp persist(nodes) do
    :persistent_term.put(@nodes_key, nodes)
  end

  defp update_size(new) do
    current = :persistent_term.get(@cluster_size_key, {-1, nil, nil})

    if new > current do
      :persistent_term.put(@cluster_size_key, new)
      :updated
    end
  end

  defp log(msg, old_nodes, new_nodes, old_cluster_size, new_cluster_size) do
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
        Logger.warning("[#{Node.self()}] Quorum lost. [#{node_stat}]")

      not old_quorum? and new_quorum? ->
        Logger.info("[#{Node.self()}] Quorum reached. [#{node_stat}]")

      n > new_cluster_size ->
        Logger.warning("[#{Node.self()}] More nodes than configured cluster size. [#{node_stat}]")

      true ->
        nil
    end
  end
end
