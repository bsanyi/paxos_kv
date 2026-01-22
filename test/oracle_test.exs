# This test creates a local model of PaxosKV. A successful test means that the
# random series of `put`, `get` and node up/down events works the same way in
# the test cluster using PaxosKV and the oracle (model based) implementation.

defmodule OracleTest do
  use ExUnit.Case
  use ExUnitProperties
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
      IO.puts(:stderr, "\n\nSeems like another node is running.")
      IO.puts(:stderr, "Please stop it before running tests.")
      assert {:ok, [{~c"node0", _port}]} = :net_adm.names()
      System.halt(1)
    end

    # Number of nodes
    n = TestHelper.get_env_int("N", default: 5)

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

  defmodule State do
    defstruct map: %{}, nodes: %{}, bad_nodes: [], n: -1
  end

  property "sequential", %{nodes: nodes, n: n} do
    node_names = Map.keys(nodes)
    {:ok, oraculum} = Agent.start_link(fn -> %State{nodes: node_names, n: n} end)
    {:ok, registry} = Agent.start_link(fn -> nodes end)

    check all(
            op <- StreamData.member_of([:put, :node_up_down]),
            node_name <- StreamData.member_of(node_names),
            key <- StreamData.member_of(1..10),
            value <- StreamData.positive_integer(),
            max_shrinking_steps: 0,
            max_runs: 500
          ) do
      node = Agent.get(registry, fn reg -> reg[node_name] end)
      node? = !!node

      case op do
        :put when node? ->
          real_result = TestHelper.call(node, PaxosKV, :put, [key, value])
          oraculum_result = Agent.get_and_update(oraculum, &put(&1, key, value))
          assert real_result == oraculum_result

        :get when node? ->
          real_result = TestHelper.call(node, PaxosKV, :get, [key])
          oraculum_result = Agent.get(oraculum, &get(&1, key))
          assert real_result == oraculum_result

        _ ->
          # This is reached on :node_up_down events and on :get/:put events when
          # the node is unreachable.
          case Agent.get_and_update(oraculum, &toggle_node(&1, node_name)) do
            :node_up ->
              node_pid = TestHelper.peer(node_name, n)
              Agent.update(registry, &Map.put(&1, node_name, node_pid))

              Helpers.wait_for(fn ->
                TestHelper.call(node_pid, GenServer, :call, [PaxosKV.Cluster, :ping]) == :pong
              end)

              Process.sleep(300)

            :node_down ->
              :peer.stop(node)
              Agent.update(registry, &Map.delete(&1, node_name))

              Process.sleep(100)
          end
      end
    end

    Agent.stop(registry)
    Agent.stop(oraculum)
  end

  ##  Oraculum implementation

  defp put(state, key, value) do
    if Helpers.quorum?(state.nodes, state.n) do
      # first write wins, further writes of the same `key` return the `value` of the first write
      new_state = %{state | map: Map.update(state.map, key, value, &Function.identity/1)}
      {{:ok, Map.get(new_state.map, key)}, new_state}
    else
      {{:error, :no_quorum}, state}
    end
  end

  defp get(state, key) do
    # returns the value associated with `key`, or `nil`
    Map.get(state.map, key)
  end

  def toggle_node(state, node_name) do
    cond do
      node_name in state.nodes ->
        new_state = %{
          state
          | nodes: state.nodes -- [node_name],
            bad_nodes: state.bad_nodes ++ [node_name]
        }

        if Enum.empty?(new_state.nodes) do
          {:node_down, %{new_state | map: %{}}}
        else
          {:node_down, new_state}
        end

      node_name in state.bad_nodes ->
        new_state = %{
          state
          | nodes: state.nodes ++ [node_name],
            bad_nodes: state.bad_nodes -- [node_name]
        }

        {:node_up, new_state}
    end
  end
end
