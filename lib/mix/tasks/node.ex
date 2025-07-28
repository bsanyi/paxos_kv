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

  def run([node_number | rest] = args) do
    node_number = String.to_integer(node_number)

    System.cmd("epmd", ["-daemon"])

    Node.start(node_name(node_number), :longnames)

    for i <- 0..(3 * node_number + 2), i != node_number do
      Node.connect(node_name(i))
    end

    Mix.Tasks.Run.run(args(rest))
  catch
    _, _ ->
      Mix.Tasks.Run.run(args(args))
  end

  defp args(args) do
    #    if iex?() do
    #      args
    #    else
    args ++ ["--no-halt"]
    #    end
  end

  #  defp iex? do
  #    Code.ensure_loaded?(IEx) and IEx.started?()
  #  end

  def node_name(n) do
    {fqdn, _} = System.cmd("hostname", ["-f"])
    :"node#{n}@#{String.trim(fqdn)}"
  end
end
