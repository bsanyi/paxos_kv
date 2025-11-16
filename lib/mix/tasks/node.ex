defmodule Mix.Tasks.Node do
  @shortdoc "Starts the node in distributed mode with a numbered node name schema."

  @moduledoc """
  #{@shortdoc}

  Every node has a number started from 0. The name of the nodes gonna be just
  simply `:node0`, `:node1`, etc.

  It also tries to connect to other nodes that are already alive. For instance,
  if you start `:node4` with the `node` task, it will try to connect to
  `:node0`, `:node1`, `:node2`, `:node3` and also some nodes like `:node5`,
  `:node6`, `:node7` and so on. That means starting `:nodeN` will try to
  connect to the previous N nodes and the next N nodes. Starting `:node0` does
  not trigger any connections. The `node` task uses long names.

  In production you must have a more sophisticated clustering strategy, like
  `libcluster`, but for development and testing the `node` task will help you
  simplify your daily tasks.

  ## Usage:

  Start an IEx shell in distributed mode with the name `node4`:

  ```bash
    $ iex -S mix node 4
  ```

  Start node number 3 without the IEx shell:

  ```bash
    $ mix node 3
  ```

  It is also possible to start nodes without manually entering numbers for them.
  Use an underscore `_` in place of the node number and the node task will find
  you the first available node number starting from 1:

  ```bash
    $ iex -S mix node _
  ```

  You can use an underscore to start a node without specifying the node number.
  In that case the task is going to figure out the smallest available node number
  and use that number.

  It is also possible to add further Mix tasks to the command line.
  """

  use Mix.Task

  @impl true
  def run([]) do
    "Enter a node number:"
    |> Mix.shell().prompt()
    |> String.trim()
    |> List.wrap()
    |> run()
  end

  def run([node_number | rest]) do
    node_number = find_node_number(node_number)

    System.cmd("epmd", ["-daemon", "-relaxed_command_check"])

    Node.start(node_name(node_number), :longnames)

    for i <- 0..(3 * node_number + 3), i != node_number do
      Node.connect(node_name(i))
    end

    if "app.start" not in rest, do: Mix.Task.run("app.start")

    continue_with_task(rest)
  end

  defp find_node_number("_") do
    {:ok, nodes} = :net_adm.names()

    available_node_numbers =
      nodes
      |> Enum.map(fn {node, _port} ->
        node
        |> to_string()
        |> String.trim_leading("node")
      end)

    1
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find(fn num -> to_string(num) not in available_node_numbers end)
  end

  defp find_node_number(node_number) do
    String.to_integer(node_number)
  end

  @doc "Returns the node name of the `n`th node."
  def node_name(n) do
    {fqdn, 0} = System.cmd("hostname", ["-f"])
    :"node#{n}@#{String.trim(fqdn)}"
  end

  defp continue_with_task([]), do: nil

  defp continue_with_task([task_name | args]) do
    Mix.Task.load_all()
    Mix.Task.rerun(task_name, args)
    # task_module = Mix.Task.get(task_name)
    # task_module.run(args)
  end
end
