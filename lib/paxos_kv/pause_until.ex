defmodule PaxosKV.PauseUntil do
  @moduledoc """
  A special GenServer that executes a function during initialization.

  This module is used to pause the supervisor's startup sequence until a given
  function completes. After executing the function, the GenServer returns
  `:ignore`, which causes it to not be added to the supervision tree.
  """

  use GenServer

  def start_link(fun) do
    GenServer.start_link(__MODULE__, fun)
  end

  def child_spec(fun) when is_function(fun, 0) do
    %{
      id: {__MODULE__, fun},
      start: {__MODULE__, :start_link, [fun]}
    }
  end

  def init(fun) do
    fun.()
    :ignore
  end
end
