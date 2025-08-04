defmodule PaxosKV.Helpers.Msg do
  @moduledoc false

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
end
