defmodule PaxosKVTest do
  use ExUnit.Case
  require PaxosKV.Helpers, as: Helpers

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
    {:ok, pid, _node} = :peer.start_link(%{name: node, longnames: true, connection: 0})
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
    for i <- 1..100, key = {:key, i}, value = i do
      {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      assert PaxosKV.put(key, value, pid: pid) == value

      assert PaxosKV.get(key) == value
      assert PaxosKV.pid(key) == pid

      Process.exit(pid, :kill)

      # assert_receive Helpers.monitor_down(ref: ^ref, type: :process, pid: ^pid, reason: _), 1_000

      if Enum.random([0, 1]) == 1 do
        assert PaxosKV.get(key, default: :default) == :default
        assert PaxosKV.pid(key) == nil
      end

      assert PaxosKV.put(key, -value, pid: self()) == -value
      assert PaxosKV.get(key) == -value
      assert PaxosKV.pid(key) == self()
    end
  end

  test "key is deleted when associated node goes down" do
    node = Mix.Tasks.Node.node_name(4)
    {:ok, node4, _} = :peer.start_link(%{name: node, longnames: true, connection: 0})
    Helpers.wait_for(fn -> Node.ping(node) == :pong end)

    {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
    {pid2, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

    value = 123
    assert value = PaxosKV.put(:monitored_1, value, node: node)
    assert value = PaxosKV.put(:monitored_2, value, node: node, pid: pid)
    assert value = PaxosKV.put(:monitored_3, value, node: node, pid: pid2)

    Process.exit(pid2, :kill)
    assert PaxosKV.get(:monitored_3, default: :default) == :default
    assert PaxosKV.put(:monitored_3, value + 1)

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
    assert PaxosKV.get(:monitored_1, default: :default) == :default
    assert PaxosKV.get(:monitored_2, default: :default) == :default

    assert PaxosKV.put(:monitored_2, 2 * value)
    Process.exit(pid, :kill)
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

      assert match?([{:ok, num}] when num in [1, 2, 3], result)
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

    assert value1 == PaxosKV.put(key, value1)
    assert value2 == PaxosKV.put(key, value2, bucket: Bucket1)
    assert value3 == PaxosKV.put(key, value3, bucket: Bucket2)
    assert value1 == PaxosKV.get(key)
    assert value2 == PaxosKV.get(key, bucket: Bucket1)
    assert value3 == PaxosKV.get(key, bucket: Bucket2)
  end

  test "cluster can be resized", %{node1: node1, node2: node2, node3: node3} do
    nodes = [node1, node2, node3]

    a = Enum.map(nodes, &call(&1, PaxosKV.Cluster, :cluster_size, []))
    assert a == [3, 3, 3]

    PaxosKV.Cluster.resize_cluster(2)
    b = Enum.map(nodes, &call(&1, PaxosKV.Cluster, :cluster_size, []))
    assert b == [2, 2, 2]

    PaxosKV.Cluster.resize_cluster(9)
    c = Enum.map(nodes, &call(&1, PaxosKV.Cluster, :cluster_size, []))
    assert c == [9, 9, 9]

    PaxosKV.Cluster.resize_cluster(3)
    d = Enum.map(nodes, &call(&1, PaxosKV.Cluster, :cluster_size, []))
    assert d == [3, 3, 3]
  end

  defp call(node, m, f, a) do
    if is_pid(node) do
      :peer.call(node, m, f, a)
    else
      :erpc.call(node, m, f, a)
    end
  end
end
