defmodule PaxosKV.Helpers do
  @moduledoc """
  Internal utility functions for PaxosKV.

  This module provides helper functions for quorum validation, process and node
  monitoring, synchronization, and value validation. These functions are used
  internally by other PaxosKV modules.
  """

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

  ## Examples

      iex> PaxosKV.Helpers.quorum?([:node1, :node2], 3)
      true

      iex> PaxosKV.Helpers.quorum?([:node1], 3)
      false

  """
  def quorum?(list, n), do: 2 * length(list) > n

  @doc """
  Monitors a process and associates it with a key.

  If the pid is not nil, it demonitors any existing monitors for the same key,
  creates a new monitor for the pid, and updates the pid_monitors map.

  Returns the updated pid_monitors map.
  """
  def monitor_pid(pid, key, pid_monitors) do
    if pid do
      new_monitors =
        for ref <- which_keys(pid_monitors, key), reduce: pid_monitors do
          acc ->
            Process.demonitor(ref, [:flush])
            Map.delete(acc, ref)
        end

      ref = Process.monitor(pid)

      Map.put(new_monitors, ref, key)
    else
      pid_monitors
    end
  end

  @doc """
  Tracks that a key is associated with a specific node.

  Updates the node_monitors map to track which keys depend on which nodes.
  Returns the updated node_monitors map.
  """
  def monitor_node(node, key, node_monitors) do
    if node do
      Map.update(node_monitors, node, MapSet.new([key]), &MapSet.put(&1, key))
    else
      node_monitors
    end
  end

  @doc """
  Tracks a dependency relationship between two keys.

  If `key` depends on `xkey`, this function updates the key_monitors map
  to record this relationship. Returns the updated key_monitors map.
  """
  def monitor_key(xkey, key, key_monitors) do
    if xkey do
      Map.update(key_monitors, xkey, MapSet.new([key]), &MapSet.put(&1, key))
    else
      key_monitors
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

  defp validate_until(%{until: time}), do: time >= PaxosKV.now()
  defp validate_until(_), do: true

  @doc """
  Checks if a process is alive, even on remote nodes.

  For local processes, uses `Process.alive?/1`. For remote processes,
  performs an RPC call to check the process status on the remote node.

  ## Examples

      iex> PaxosKV.Helpers.process_alive?(self())
      true

  """
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

  @doc """
  Checks if a node is alive and connected.

  Returns `true` if the node responds to ping, `false` otherwise.

  ## Examples

      iex> PaxosKV.Helpers.node_alive?(Node.self())
      true

  """
  def node_alive?(node) do
    Node.ping(node) == :pong
  end

  @doc """
  Sleeps for a random duration between 0 and 750 milliseconds.

  Used for implementing randomized backoff when retrying operations
  to avoid thundering herd problems.
  """
  def random_backoff do
    0..750
    |> Enum.random()
    |> Process.sleep()
  end
end
