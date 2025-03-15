defmodule PaxosKV.PauseUntil do
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
