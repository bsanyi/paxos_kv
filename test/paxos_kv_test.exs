defmodule PaxosKVTest do
  use ExUnit.Case
  alias PaxosKV.Helpers
  require PaxosKV.Helpers.Msg, as: Msg

  setup_all do
    ##  Restart the origin node with longnames:
    Application.stop(:paxos_kv)
    Node.start(:node1, :longnames)
    Application.start(:paxos_kv)

    ##  Start two more peers and connect to them:
    node2 = peer(:node2)
    node3 = peer(:node3)

    ##  Give some prepare time to the peers:
    Helpers.wait_for(fn -> call(node2, PaxosKV.Cluster, :ping, []) == :pong end)
    Helpers.wait_for(fn -> call(node3, PaxosKV.Cluster, :ping, []) == :pong end)

    [node1: Node.self(), node2: node2, node3: node3]
  end

  defp peer(node) do
    {:ok, pid, _node} = :peer.start_link(%{name: node, longnames: true, connection: 0, shutdown: :close})
    remote_paths = call(pid, :code, :get_path, [])

    for path <- :code.get_path(), path not in remote_paths do
      call(pid, :code, :add_patha, [path])
    end

    for app <- ~w[compiler elixir logger runtime_tools wx observer paxos_kv]a do
      call(pid, :application, :ensure_started, [app])
    end

    call(pid, Logger, :configure, [[level: :error]])

    call(pid, Node, :connect, [Node.self()])

    pid
  end

  test "key is deleted when associated pid dies" do
    for i <- 1..200, key = {:key, i}, value = i do
      {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      assert PaxosKV.put(key, value, pid: pid) == {:ok, value}

      assert PaxosKV.get(key) == value
      assert PaxosKV.pid(key) == pid

      Process.exit(pid, :kill)

      assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid, reason: _), 1_000

      if Enum.random([0, 1]) == 1 do
        assert PaxosKV.get(key, default: {:default, i}) == {:default, i}
        assert PaxosKV.pid(key) == nil
      end

      assert PaxosKV.put(key, -value, pid: self()) == {:ok, -value}
      assert PaxosKV.get(key) == -value
      assert PaxosKV.pid(key) == self()
    end
  end

  test "cannot register if pid or node not alive" do
    pid = spawn(fn -> nil end)
    node = Node.self() |> to_string() |> String.replace("node1@", "node666@") |> String.to_atom()

    assert {:error, :invalid_value} == PaxosKV.put(:some_key, :some_value, pid: pid)
    assert {:error, :invalid_value} == PaxosKV.put(:some_key, :some_value, node: node)
    assert {:error, :invalid_value} == PaxosKV.put(:some_key, :some_value, pid: pid, node: node)
    assert {:error, :invalid_value} != PaxosKV.put(:some_key, :some_value, pid: self())
  end

  test "key is deleted when associated node goes down" do
    node = Mix.Tasks.Node.node_name(4)
    {:ok, node4, _} = :peer.start_link(%{name: node, longnames: true, connection: 0, shutdown: :close})

    {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
    {pid2, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

    value = 123
    assert {:ok, value} = PaxosKV.put(:monitored_1, value, node: node)
    assert {:ok, value} = PaxosKV.put(:monitored_2, value, node: node, pid: pid)
    assert {:ok, value} = PaxosKV.put(:monitored_3, value, node: node, pid: pid2)

    Process.exit(pid2, :kill)
    assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid2, reason: _), 1_000

    assert PaxosKV.get(:monitored_3, default: :default_3) == :default_3
    assert {:ok, value + 1} == PaxosKV.put(:monitored_3, value + 1)

    assert PaxosKV.get(:monitored_1) == value
    assert PaxosKV.get(:monitored_2) == value
    assert PaxosKV.get(:monitored_1) == value
    assert PaxosKV.get(:monitored_2) == value
    assert PaxosKV.get(:monitored_1) == value
    assert PaxosKV.get(:monitored_2) == value
    assert PaxosKV.node(:monitored_1) == node
    assert PaxosKV.node(:monitored_2) == node
    assert PaxosKV.pid(:monitored_2) == pid

    :peer.stop(node4)

    # Give some time to `node4` to stop and to Acceptors to detect the `:nodedown` event:
    Process.sleep(100)

    assert PaxosKV.get(:monitored_1, default: :default_1) == :default_1
    assert PaxosKV.get(:monitored_2, default: :default_2) == :default_2

    PaxosKV.put(:monitored_2, 2 * value)

    Process.exit(pid, :kill)
    assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid, reason: _), 1_000

    assert PaxosKV.get(:monitored_2) == 2 * value

    assert PaxosKV.get(:monitored_3) == value + 1
  end

  test "reaches consensus", %{node2: node2, node3: node3} do
    for i <- 1..5, key = {{{i}}} do
      result =
        [
          fn -> call(node3, PaxosKV, :put, [key, 3]) end,
          fn -> call(node2, PaxosKV, :put, [key, 2]) end,
          fn -> PaxosKV.put(key, 1) end
        ]
        |> Task.async_stream(fn f -> f.() end, max_concurrency: 3, ordered: false)
        |> Enum.to_list()
        |> Enum.uniq()

      assert match?([{:ok, {:ok, num}}] when num in [1, 2, 3], result)
    end
  end

  test "can use separate buckets", %{node2: node2, node3: node3} do
    for bucket <- [Bucket1, Bucket2] do
      child = {PaxosKV.Bucket, bucket: bucket}

      call(node3, Supervisor, :start_child, [PaxosKV.RootSup, child])
      call(node2, Supervisor, :start_child, [PaxosKV.RootSup, child])
      Supervisor.start_child(PaxosKV.RootSup, child)
    end

    value1 = "one"
    value2 = "two"
    value3 = "three"

    assert length(Enum.uniq([value1, value2, value3])) == 3

    key = :the_same_key_for_all_buckets

    assert {:ok, value1} == PaxosKV.put(key, value1)
    assert {:ok, value2} == PaxosKV.put(key, value2, bucket: Bucket1)
    assert {:ok, value3} == PaxosKV.put(key, value3, bucket: Bucket2)
    assert value1 == PaxosKV.get(key)
    assert value2 == PaxosKV.get(key, bucket: Bucket1)
    assert value3 == PaxosKV.get(key, bucket: Bucket2)
  end

  test "cluster can be resized", %{node1: node1, node2: node2, node3: node3} do
    nodes = [node1, node2, node3]
    assert [3, 3, 3] == cluster_sizes(nodes)

    PaxosKV.Cluster.subscribe()
    assert_receive :quorum_reached

    assert :ok == PaxosKV.Cluster.resize_cluster(9)
    assert [9, 9, 9] == cluster_sizes(nodes)
    assert_receive :quorum_lost

    assert :ok == PaxosKV.Cluster.resize_cluster(1)
    assert [1, 1, 1] == cluster_sizes(nodes)
    assert_receive :quorum_reached

    assert :ok == PaxosKV.Cluster.resize_cluster(2)
    assert [2, 2, 2] == cluster_sizes(nodes)
    refute_receive :quorum_reached

    PaxosKV.Cluster.unsubscribe()

    assert :ok == PaxosKV.Cluster.resize_cluster(1)
    assert [1, 1, 1] == cluster_sizes(nodes)

    assert :ok == PaxosKV.Cluster.resize_cluster(3)
    assert [3, 3, 3] == cluster_sizes(nodes)

    assert :ok == PaxosKV.Cluster.resize_cluster(9)
    assert [9, 9, 9] == cluster_sizes(nodes)

    refute_receive :quorum_reached
    refute_receive :quorum_lost

    PaxosKV.Cluster.resize_cluster(3)
  end

  defp cluster_sizes(nodes) do
    Enum.map(nodes, &call(&1, PaxosKV.Cluster, :cluster_size, []))
  end

  defp call(node, m, f, a) do
    if is_pid(node) do
      :peer.call(node, m, f, a)
    else
      :erpc.call(node, m, f, a)
    end
  end
end
