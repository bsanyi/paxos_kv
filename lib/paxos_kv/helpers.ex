defmodule PaxosKV.Helpers do
  @moduledoc false

  @doc """
  Returns the current time that can be used in the `until: ...` option.
  The time is measured in milliseconds and is actually the system time.
  """
  def now, do: System.system_time(:millisecond)

  @doc """
  This is a synchronization function. It blocks the caller until the `predicate`
  function returns a truthy value (anything but `nil` or `false`).
  """
  def wait_for(predicate, sleep_period_ms \\ 300, counter \\ 0) do
    pred? =
      try do
        predicate.()
      catch
        _, _ -> false
      end

    if pred? do
      counter
    else
      Process.sleep(sleep_period_ms)
      wait_for(predicate, sleep_period_ms, counter + 1)
    end
  end

  @doc """
  Blocks until the bucket's learner, acceptor, and proposer processes are ready.
  """
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

  def monitor_key(xkey, key, monitors) do
    if xkey do
      Map.update(monitors, xkey, [key], &Enum.uniq([key | &1]))
    else
      monitors
    end
  end

  @doc """
  Removes all the given messages from the process mailbox.
  """
  def flush_messages([msg | rest]) do
    receive do
      ^msg -> :ok
    after
      0 -> :ok
    end

    flush_messages(rest)
  end

  def flush_messages([]), do: :ok

  defp which_keys(map, value) do
    for {k, v} <- map, v == value, do: k
  end

  @doc """
  Returns `{bucket_name, full_module_name}` for the given bucket suffix.
  """
  def name(opts, bucket_suffix) do
    bucket = Keyword.get(opts, :bucket, PaxosKV)
    {bucket, Module.concat(bucket, bucket_suffix)}
  end

  @doc """
  Checks if a value-metadata tuple is still valid (pid alive, node connected, time not expired).
  """
  def still_valid?({_, meta}) do
    true &&
      validate_pid(meta) &&
      validate_node(meta) &&
      validate_until(meta)
  catch
    _ -> false
  end

  defp validate_pid(%{pid: pid}), do: process_alive?(pid)
  defp validate_pid(_), do: true

  defp validate_node(%{node: node}), do: node_alive?(node)
  defp validate_node(_), do: true

  defp validate_until(%{until: time}), do: time >= now()
  defp validate_until(_), do: true

  def process_alive?(pid) when is_pid(pid) do
    node = :erlang.node(pid)

    if node == Node.self() do
      Process.alive?(pid)
    else
      :erpc.call(node, Process, :alive?, [pid])
    end
  catch
    _, _ ->
      false
  end

  def node_alive?(node) do
    Node.ping(node) == :pong
  end

  def random_backoff do
    0..750
    |> Enum.random()
    |> Process.sleep()
  end
end
