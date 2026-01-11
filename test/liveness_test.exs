# This test creates a large number of simultaneous processes that try to
# populate the same key at the same time. It prooves that despite the fact that
# basic paxos is not live, this implementation **is** live.
#
# Usage:
#
#   D=3 N=5 mix test test/liveness_test.exs
#
# N: number of nodes in the test cluster (default: 5)
#
# D: the depth of the tree of processes where the leaves are those processes
#    writing to the KV store at once. (default: 3)
#
# The assertions are:
#
# 1. it is **live** -- meaning that the `put` call returns in every process
# 2. it is **safe** -- meaning that
#   - there is only a single result for all `put` calls everywhere in the cluster
#   - the result is one of the proposed values, not a made up one

defmodule LivenessTest do
  use ExUnit.Case
  alias PaxosKV.Helpers

  @moduletag timeout: :timer.minutes(30)

  setup_all do
    TestHelper.init_epmd()

    ##  Restart the origin node with longnames:
    Application.stop(:paxos_kv)
    TestHelper.retry(fn ->
      Node.stop()
      Node.start(:node0, :longnames)
    end)
    # We deliberately not start the service on node0.

    if Node.self() == :nonode@nohost or not match?({:ok, [{~c"node0", _port}]}, :net_adm.names()) do
      IO.puts :stderr, "\n\nSeems like another node is running."
      IO.puts :stderr, "Please stop it before running tests."
      assert {:ok, [{~c"node0", _port}]} = :net_adm.names()
      System.halt(1)
    end

    # Number of nodes
    n = TestHelper.get_env_int("N", default: 5)

    # Depth of process tree
    d = TestHelper.get_env_int("D", default: 3)

    ##  Start N peers and connect to them:
    nodes = for i <- 1..n do
      name = :"node#{i}"
      node = TestHelper.peer(name, n)
      root_pid = spawn_chaos(node, d)
      {i, name, node, root_pid}
    end

    ##  Give some prepare time to the peers:
    for {_i, _name, node, _root} <- nodes do
      Helpers.wait_for(fn -> TestHelper.call(node, PaxosKV.Cluster, :quorum?, []) == true end)
    end

    Process.sleep(100)

    on_exit(fn ->
      for {_, _name, node, _root} <- nodes do
        TestHelper.tear_down(node)
      end
      Node.stop()
    end)

    [nodes: Enum.shuffle(nodes)]
  end

  defp spawn_chaos(node, n) do
    TestHelper.call(node, :erlang, :spawn_link, [Chaos.loop(n)])
  end

  test "key1", %{nodes: nodes} do
    test_round(nodes, :key1, 1..10)
  end

  test "key2", %{nodes: nodes} do
    test_round(nodes, :key2, 2..100)
  end

  test "key3", %{nodes: nodes} do
    test_round(nodes, :key3, 3..1000)
  end

  defp test_round(nodes, key, values) do
    nodes = Enum.shuffle(nodes)

    values = Enum.to_list(values)
    me = self()

    for {_i, _name, _node, root_pid} <- nodes do
      send(root_pid, {:put, key, values, me})
    end

    unique_responses =
      nodes
      |> Enum.flat_map(fn _ ->
        receive do
          {:reply, r} -> r
        end
      end)
      |> Enum.uniq()

    assert [{:ok, value}] = unique_responses
    assert value in values
  end
end
