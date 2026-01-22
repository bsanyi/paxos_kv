defmodule PaxosKV.Helpers.Msg do
  @moduledoc """
  Macros for pattern matching common Erlang messages.

  This module provides convenient macros for matching against node monitoring
  messages, task replies, and process monitor DOWN messages.
  """

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
