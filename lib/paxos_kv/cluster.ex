defmodule PaxosKV.Cluster do
  ############################################
  ####  Elixir/Erlang/OTP API

  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  @nodes_key Module.concat(__MODULE__, Nodes)
  @cluster_size_key Module.concat(__MODULE__, ClusterSize)

  def nodes do
    :persistent_term.get(@nodes_key, [])
  end

  def cluster_size do
    :persistent_term.get(@cluster_size_key)
  end

  def nodes_and_cluster_size do
    {nodes(), cluster_size()}
  end

  def resize_cluster(_new_size) do
    # ...
  end

  ############################################
  ####  Elixir/Erlang/OTP API

  require PaxosKV.Helpers, as: Helpers

  def start_link(opts) do
    cluster_size = Keyword.fetch!(opts, :cluster_size)
    GenServer.start_link(__MODULE__, cluster_size, name: __MODULE__)
  end

  ############################################
  ####  GenServer implmentation

  use GenServer

  require Logger

  @impl true
  def init(cluster_size) do
    if Node.alive? do
      :net_kernel.monitor_nodes(true)

      :persistent_term.put(@cluster_size_key, cluster_size)

      for node <- Node.list([:visible, :this]) do
        send(self(), Helpers.nodeup(node))
      end

      {:ok, {cluster_size, []}}
    else
      Logger.error("Node is not started in distributed mode.")
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

  @impl true
  def handle_info(Helpers.nodeup(node), state) do
    Task.async(__MODULE__, :wait_for_node_ready, [node])
    Logger.debug("[#{Node.self()}] Node #{node} connected.")
    {:noreply, state}
  end

  def handle_info(Helpers.nodedown(node), {n, nodes}) do
    new_nodes = Enum.reject(nodes, &(&1 == node))
    persist(new_nodes)
    log("Node #{node} is down.", nodes, new_nodes, n)
    {:noreply, {n, new_nodes}}
  end

  def handle_info(Helpers.task_reply(ref: ref, reply: node), {n, nodes}) when is_reference(ref) and is_atom(node) do
    Process.demonitor(ref, [:flush])
    new_nodes = Enum.uniq([node | nodes])
    persist(new_nodes)
    log("Node #{node} is up.", nodes, new_nodes, n)
    {:noreply, {n, new_nodes}}
  end

  def wait_for_node_ready(node) do
    Helpers.wait_for(fn -> GenServer.call({__MODULE__, node}, :ping) == :pong end)
    node
  end

  defp persist(nodes) do
    :persistent_term.put(@nodes_key, nodes)
  end

  defp log(msg, old_nodes, new_nodes, cluster_size) do
    old_quorum? = Helpers.quorum?(old_nodes, cluster_size)
    new_quorum? = Helpers.quorum?(new_nodes, cluster_size)
    quorum = if new_quorum?, do: "quorum:yes", else: "quorum:no"

    n = length(new_nodes)
    node_stat = "cluster:#{n}/#{cluster_size}"

    Logger.info("[#{Node.self()}] #{msg} [#{node_stat}] [#{quorum}]")

    cond do
      old_quorum? and not new_quorum? ->
        Logger.warning("[#{Node.self()}] Quorum lost. [#{node_stat}]")

      not old_quorum? and new_quorum? ->
        Logger.info("[#{Node.self()}] Quorum reached. [#{node_stat}]")

      n > cluster_size ->
        Logger.error("[#{Node.self()}] More nodes than configured cluster size. [#{node_stat}]")

      true ->
        nil
    end
  end
end
