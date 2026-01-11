defmodule RollingRestartTest do
  use ExUnit.Case
  use ExUnitProperties
  alias PaxosKV.Helpers

  @moduletag timeout: :timer.minutes(30)

  setup_all do
    TestHelper.init_epmd()

    Application.stop(:paxos_kv)
    TestHelper.retry(fn ->
      Node.stop()
      Node.start(:node0, :longnames)
    end)

    if Node.self() == :nonode@nohost or not match?({:ok, [{~c"node0", _port}]}, :net_adm.names()) do
      IO.puts(:stderr, "\n\nSeems like another node is running.")
      IO.puts(:stderr, "Please stop it before running tests.")
      assert {:ok, [{~c"node0", _port}]} = :net_adm.names()
      System.halt(1)
    end

    # Number of nodes
    n = TestHelper.get_env_int("N", default: 3)

    ##  Start N peers and connect to them:
    nodes =
      for i <- 1..n, into: %{} do
        name = :"node#{i}"
        node_pid = TestHelper.peer(name, n)
        {name, node_pid}
      end

    ##  Give some prepare time to the peers:
    for {_name, node_pid} <- nodes do
      Helpers.wait_for(fn -> TestHelper.call(node_pid, PaxosKV.Cluster, :quorum?, []) == true end)
    end

    Process.sleep(100)

    on_exit(fn ->
      for {_name, node_pid} <- nodes do
        TestHelper.tear_down(node_pid)
      end

      Node.stop()
    end)

    [nodes: nodes, n: n]
  end

  test "rolling upgrade", %{nodes: nodes, n: n} do
    node_names =
      for {_name, node_pid} <- nodes do
        :peer.call(node_pid, Node, :self, [])
      end

    assert {:ok, V1} = exec_on_a_node(nodes, :put, [K1, V1])
    assert {:ok, V2} = exec_on_a_node(nodes, :put, [K2, V2])
    assert {:ok, V3} = exec_on_a_node(nodes, :put, [K3, V3])
    assert {:ok, V4} = exec_on_a_node(nodes, :put, [K4, V4, [node: Node.self()]])
    assert {:ok, V5} = exec_on_a_node(nodes, :put, [K5, V5, [node: Enum.random(node_names)]])
    assert {:ok, V6} = exec_on_a_node(nodes, :put, [K6, V6, [node: Enum.random(node_names)]])
    assert {:ok, V7} = exec_on_a_node(nodes, :put, [K7, V7, [node: Enum.random(node_names)]])

    :net_kernel.monitor_nodes(true)

    nodes =
      nodes
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> Enum.reverse()
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> Enum.shuffle()
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> rolling_restart(n)
      |> Enum.shuffle()
      |> rolling_restart(n)
      |> Enum.shuffle()
      |> rolling_restart(n)
      |> Enum.shuffle()
      |> rolling_restart(n)

    # First three keys are kept:
    assert {:ok, V1} == exec_on_a_node(nodes, :get, [K1])
    assert {:ok, V2} == exec_on_a_node(nodes, :put, [K2, A])
    assert {:ok, V3} == exec_on_a_node(nodes, :put, [K3, B, [pid: self()]])

    # V4 is kept, because node0 was not restarted, only 1..N nodes:
    assert {:ok, V4} == exec_on_a_node(nodes,  :put, [K4, C, [host: Enum.random(node_names)]])

    # K5, K6, K7 is lost and can be re-registered, because of `node:` options:
    assert {:ok, D} == exec_on_a_node(nodes, :put, [K5, D, [host: Enum.random(node_names)]])
    assert {:ok, E} == exec_on_a_node(nodes, :put, [K6, E, [host: Enum.random(node_names)]])
    assert {:error, :not_found} == exec_on_a_node(nodes, :get, [K7])
  end

  def exec_on_a_node(nodes, op, args) do
    {_name, node_pid} = Enum.random(nodes)
    :peer.call(node_pid, PaxosKV, op, args)
  end

  defp rolling_restart(nodes, n) do
    for {node, node_pid} <- nodes, reduce: nodes do
      nodes ->
        :peer.stop(node_pid)

        Helpers.wait_for(fn ->
          res =
            receive do
              {:nodedown, _} -> :ok
            after 10_000 ->
              :err
            end

          res == :ok
        end)

        new_node_pid = TestHelper.peer(node, n)
        Helpers.wait_for(fn -> TestHelper.call(new_node_pid, PaxosKV.Cluster, :quorum?, []) == true end)

        Enum.map(nodes, fn
          {^node, _pid} -> {node, new_node_pid}
          other -> other
        end)
    end
  end
end
