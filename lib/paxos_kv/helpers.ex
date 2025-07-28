defmodule PaxosKV.Helpers do
  @moduledoc false

  @doc """
  This is a syncronization function. It blocks the caller until the `predicate`
  function returns a truthy value (anything but `nil` or `false`).
  """
  def wait_for(predicate, sleep_period_ms \\ 300) do
    pred? =
      try do
        predicate.()
      catch
        _, _ -> false
      end

    unless pred? do
      Process.sleep(sleep_period_ms)
      wait_for(predicate, sleep_period_ms)
    end
  end

  def wait_for_bucket(bucket) do
    learner = Module.concat(bucket, Learner)
    acceptor = Module.concat(bucket, Acceptor)
    proposer = Module.concat(bucket, Proposer)

    wait_for(fn -> GenServer.call(learner, :ping) == :pong end)
    wait_for(fn -> GenServer.call(acceptor, :ping) == :pong end)
    wait_for(fn -> GenServer.call(proposer, :ping) == :pong end)
  end

  @doc """
  Checks if the `list` contains enough elements (node names, replies from
  nodes, etc.) to consider it a quorum.
  """
  def quorum?(list, n), do: 2 * length(list) > n

  def monitor_pid(pid, key, monitors) do
    if pid do
      new_monitors =
        for ref <- which_keys(monitors, key), reduce: monitors do
          acc ->
            Process.demonitor(ref, [:flush])
            Map.delete(acc, ref)
        end

      ref = Process.monitor(pid)

      Map.put(new_monitors, ref, key)
    else
      monitors
    end
  end

  def monitor_node(node, key, monitors) do
    if node do
      Map.update(monitors, node, [key], &Enum.uniq([key | &1]))
    else
      monitors
    end
  end

  defp which_keys(map, value) do
    for {k, v} <- map, v == value, do: k
  end

  defmacro nodeup(node) do
    quote do
      {:nodeup, unquote(node)}
    end
  end

  defmacro nodedown(node) do
    quote do
      {:nodedown, unquote(node)}
    end
  end

  defmacro task_reply(ref: ref, reply: reply) do
    quote do
      {unquote(ref), unquote(reply)}
    end
  end

  defmacro monitor_down(ref: ref, type: type, pid: pid, reason: reason) do
    quote do
      {:DOWN, unquote(ref), unquote(type), unquote(pid), unquote(reason)}
    end
  end

  def name(opts, suffix) do
    bucket = Keyword.get(opts, :bucket, PaxosKV)
    {bucket, Module.concat(bucket, suffix)}
  end

  def still_valid?({_, %{pid: pid, node: node}}), do: process_alive?(pid) and node_alive?(node)
  def still_valid?({_, %{pid: pid}}), do: process_alive?(pid)
  def still_valid?({_, %{node: node}}), do: node_alive?(node)
  def still_valid?(_), do: true

  def process_alive?(pid) when is_pid(pid) do
    node = :erlang.node(pid)

    if node == Node.self() do
      Process.alive?(pid)
    else
      :rpc.call(node, Process, :alive?, [pid])
    end
  catch
    _, _ ->
      false
  end

  def process_valid?(_), do: false

  def node_alive?(node) do
    Node.ping(node) == :pong
  end

  def random_backoff do
    0..750
    |> Enum.random()
    |> Process.sleep()
  end
end
