defmodule PaxosKVTest do
  use ExUnit.Case
  require PaxosKV.Helpers, as: Helpers

  setup do
    ##  Restart the origin node with longnames:
    Application.stop(:paxos_kv)
    Node.start(:node1, :longnames)
    Application.start(:paxos_kv)

    ##  Start two more peers and connect to them:
    node2 = peer(:node2)
    node3 = peer(:node3)

    ##  Give some prepare time to the peers:
    Helpers.wait_for(fn -> :peer.call(node2, PaxosKV.Cluster, :ping, []) == :pong end)
    Helpers.wait_for(fn -> :peer.call(node3, PaxosKV.Cluster, :ping, []) == :pong end)

    [node2: node2, node3: node3]
  end

  defp peer(node) do
    {:ok, pid, _node} = :peer.start_link(%{name: node, longnames: true, connection: 0})
    remote_paths = :peer.call(pid, :code, :get_path, [])

    for path <- :code.get_path(), path not in remote_paths do
      :peer.call(pid, :code, :add_patha, [path])
    end

    for app <- ~w[compiler elixir logger runtime_tools wx observer paxos_kv]a do
      :peer.call(pid, :application, :ensure_started, [app])
    end

    :peer.call(pid, Node, :connect, [Node.self()])

    pid
  end

  test "key is deleted when associated pid dies" do
    for i <- 1..100, key = {:key, i}, value = i do
      {pid, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      assert PaxosKV.put(key, value, pid: pid) == value

      assert PaxosKV.get(key) == value
      assert PaxosKV.pid(key) == pid

      Process.exit(pid, :kill)
      assert_receive Helpers.monitor_down(ref: ^ref, type: :process, pid: ^pid, reason: _), 1_000

      assert PaxosKV.get(key, default: :default) == :default
      assert PaxosKV.pid(key) == nil

      assert PaxosKV.put(key, -value, pid: self()) == -value
      assert PaxosKV.get(key) == -value
      assert PaxosKV.pid(key) == self()
    end
  end

  test "reaches consensus", %{node2: node2, node3: node3} do
    for i <- 1..5, key = {{{i}}} do
      result =
        [
          fn -> :peer.call(node3, PaxosKV, :put, [key, 3]) end,
          fn -> :peer.call(node2, PaxosKV, :put, [key, 2]) end,
          fn -> PaxosKV.put(key, 1) end
        ]
        |> Task.async_stream(fn f -> f.() end, max_concurrency: 3, ordered: false)
        |> Enum.to_list()
        |> Enum.uniq()

      assert match?([{:ok, num}] when num in [1, 2, 3], result)
    end
  end

  test "can use separate buckets", %{node2: node2, node3: node3} do
    for bucket <- [Bucket1, Bucket2], name <- [Learner, Acceptor, Proposer] do
      module = Module.concat(PaxosKV, name)
      id = Module.concat(bucket, name)
      child = Supervisor.child_spec({module, bucket: bucket}, id: id)

      :peer.call(node3, Supervisor, :start_child, [PaxosKV.RootSup, child])
      :peer.call(node2, Supervisor, :start_child, [PaxosKV.RootSup, child])
      Supervisor.start_child(PaxosKV.RootSup, child)
    end

    # Give some time for the new buckets to start up:
    Process.sleep(300)

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
end
