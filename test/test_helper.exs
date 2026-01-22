ExUnit.start()

defmodule TestHelper do
  def init_epmd do
    case System.cmd("epmd", ["-kill"], stderr_to_stdout: true) do
      {"Killed\n", 0} -> :ok
      {"epmd: Cannot connect to local epmd\n", 1} -> :ok
      _ -> System.cmd("killall", ["-9", "epmd"])
    end

    System.cmd("epmd", ["-daemon", "-relaxed_command_check"])
  end

  def peer(node_name, n) do
    {:ok, pid, _node} =
      :peer.start_link(%{name: node_name, longnames: true, connection: 0, shutdown: :close})

    remote_paths = TestHelper.call(pid, :code, :get_path, [])

    for path <- :code.get_path(), path not in remote_paths do
      TestHelper.call(pid, :code, :add_patha, [path])
    end

    for app <- ~w[compiler elixir logger runtime_tools wx observer stream_data]a do
      TestHelper.call(pid, :application, :ensure_started, [app])
    end

    TestHelper.call(pid, :application, :set_env, [:paxos_kv, :cluster_size, n])
    TestHelper.call(pid, :application, :ensure_started, [:paxos_kv])

    TestHelper.call(pid, Logger, :configure, [[level: :error]])

    TestHelper.call(pid, Node, :connect, [Node.self()])

    PaxosKV.Helpers.wait_for(fn -> TestHelper.call(pid, PaxosKV.Cluster, :ping, []) == :pong end)

    pid
  end

  def tear_down(node) do
    :peer.stop(node)
  catch
    _, _ -> nil
  end

  def call(node, m, f, a) do
    cond do
      is_pid(node) -> :peer.call(node, m, f, a)
      is_atom(node) -> :erpc.call(node, m, f, a)
    end
  end

  def get_env_int(name, default: int) do
    name
    |> System.get_env(to_string(int))
    |> String.to_integer()
  end

  def retry(fun, count \\ 10)

  def retry(_fun, 0), do: throw(:too_many_retries)

  def retry(fun, count) when count > 0 do
    {:ok, _} = fun.()
  catch
    _, _ ->
      Process.sleep(max(0, (8 - count) * 100))
      retry(fun, count - 1)
  end
end
