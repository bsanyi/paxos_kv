defmodule PaxosKVTest do
  use ExUnit.Case
  alias PaxosKV.Helpers
  require PaxosKV.Helpers.Msg, as: Msg

  setup_all do
    TestHelper.init_epmd()

    ##  Restart the origin node with longnames:
    Application.stop(:paxos_kv)

    TestHelper.retry(fn ->
      Node.stop()
      Node.start(:node1, :longnames)
    end)

    Application.start(:paxos_kv)

    if Node.self() == :nonode@nohost or not match?({:ok, [{~c"node1", _port}]}, :net_adm.names()) do
      IO.puts(:stderr, "\n\nSeems like another node is running.")
      IO.puts(:stderr, "Please stop is before running tests.")
      assert {:ok, [{~c"node1", _port}]} = :net_adm.names()
      System.halt(1)
    end

    ##  Start two more peers and connect to them:
    node2 = TestHelper.peer(:node2, 3)
    node3 = TestHelper.peer(:node3, 3)

    ##  Give some prepare time to the peers:
    Helpers.wait_for(fn -> TestHelper.call(node2, PaxosKV.Cluster, :quorum?, []) == true end)
    Helpers.wait_for(fn -> TestHelper.call(node3, PaxosKV.Cluster, :quorum?, []) == true end)

    on_exit(fn ->
      TestHelper.tear_down(node2)
      TestHelper.tear_down(node3)
      Node.stop()
    end)

    [node1: Node.self(), node2: node2, node3: node3]
  end

  test "key is deleted when associated pid dies" do
    for i <- 1..200, key = {:key, i}, value = i do
      {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      assert PaxosKV.put(key, value, pid: pid) == {:ok, value}

      assert PaxosKV.get(key) == {:ok, value}
      assert PaxosKV.pid(key) == {:ok, pid}

      Process.exit(pid, :kill)

      assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid, reason: _), 1_000

      if Enum.random([0, 1]) == 1 do
        assert PaxosKV.get(key, default: {:default, i}) == {:ok, {:default, i}}
        assert PaxosKV.pid(key) == {:error, :not_found}
      end

      assert PaxosKV.put(key, -value, pid: self()) == {:ok, -value}
      assert PaxosKV.get(key) == {:ok, -value}
      assert PaxosKV.pid(key) == {:ok, self()}
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

    {:ok, node4, _} =
      :peer.start_link(%{name: node, longnames: true, connection: 0, shutdown: :close})

    {pid, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
    {pid2, _ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

    value = 123
    assert {:ok, value} = PaxosKV.put(:monitored_1, value, node: node)
    assert {:ok, value} = PaxosKV.put(:monitored_2, value, node: node, pid: pid)
    assert {:ok, value} = PaxosKV.put(:monitored_3, value, node: node, pid: pid2)

    Process.exit(pid2, :kill)
    assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid2, reason: _), 1_000

    assert PaxosKV.get(:monitored_3, default: :default_3) == {:ok, :default_3}
    assert {:ok, value + 1} == PaxosKV.put(:monitored_3, value + 1)

    assert PaxosKV.get(:monitored_1) == {:ok, value}
    assert PaxosKV.get(:monitored_2) == {:ok, value}
    assert PaxosKV.get(:monitored_1) == {:ok, value}
    assert PaxosKV.get(:monitored_2) == {:ok, value}
    assert PaxosKV.get(:monitored_1) == {:ok, value}
    assert PaxosKV.get(:monitored_2) == {:ok, value}
    assert PaxosKV.node(:monitored_1) == {:ok, node}
    assert PaxosKV.node(:monitored_2) == {:ok, node}
    assert PaxosKV.pid(:monitored_2) == {:ok, pid}

    :peer.stop(node4)

    # Give some time to `node4` to stop and to Acceptors to detect the `:nodedown` event:
    Process.sleep(100)

    assert PaxosKV.get(:monitored_1, default: :default_1) == {:ok, :default_1}
    assert PaxosKV.get(:monitored_2, default: :default_2) == {:ok, :default_2}

    PaxosKV.put(:monitored_2, 2 * value)

    Process.exit(pid, :kill)
    assert_receive Msg.monitor_down(ref: _, type: :process, pid: ^pid, reason: _), 1_000

    assert PaxosKV.get(:monitored_2) == {:ok, 2 * value}

    assert PaxosKV.get(:monitored_3) == {:ok, value + 1}
  end

  test "entry can depend on another key" do
    assert {:error, :invalid_value} = PaxosKV.put(:key1, :value1, key: NON_EXISTENT_KEY)
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, :value1} == PaxosKV.put(:key1, :value1, pid: pid)
    assert {:ok, :value2} == PaxosKV.put(:key2, :value2, key: :key1)
    assert {:ok, :value1} == PaxosKV.get(:key1)
    assert {:ok, :value2} == PaxosKV.get(:key2)
    Process.exit(pid, :kill)
    assert {:error, :not_found} == PaxosKV.get(:key1)
    assert {:error, :not_found} == PaxosKV.get(:key2)
    assert {:ok, :value3} == PaxosKV.put(:key2, :value3)
  end

  test "KV pairs can have a due date" do
    value = "value"
    other_value = value <> "2"
    assert {:error, :invalid_value} == PaxosKV.put(:until1, value, until: Helpers.now() - 1)
    :erlang.garbage_collect()
    :erlang.yield()
    assert {:ok, value} == PaxosKV.put(:until2, value, until: Helpers.now() + 50)
    assert {:ok, value} == PaxosKV.get(:until2)
    Process.sleep(50 + 1)
    assert {:error, :not_found} == PaxosKV.get(:until2)

    assert {:ok, other_value} ==
             PaxosKV.put(:until2, other_value, until: Helpers.now() + :timer.seconds(2))
  end

  test "reaches consensus", %{node2: node2, node3: node3} do
    for i <- 1..5, key = {{{i}}} do
      result =
        [
          fn -> TestHelper.call(node3, PaxosKV, :put, [key, 3]) end,
          fn -> TestHelper.call(node2, PaxosKV, :put, [key, 2]) end,
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

      TestHelper.call(node3, Supervisor, :start_child, [PaxosKV.RootSup, child])
      TestHelper.call(node2, Supervisor, :start_child, [PaxosKV.RootSup, child])
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
    assert {:ok, value1} == PaxosKV.get(key)
    assert {:ok, value2} == PaxosKV.get(key, bucket: Bucket1)
    assert {:ok, value3} == PaxosKV.get(key, bucket: Bucket2)
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
    Enum.map(nodes, &TestHelper.call(&1, PaxosKV.Cluster, :cluster_size, []))
  end
end
