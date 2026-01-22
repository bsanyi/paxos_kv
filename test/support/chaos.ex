defmodule Chaos do
  @moduledoc """
  This module is part of the testing suite.
  """

  def loop(n) do
    f =
      fn
        {:root, n}, f ->
          if n > 0 do
            children = for _ <- 1..5, do: spawn_link(fn -> f.({:root, n - 1}, f) end)
            f.({:node, children}, f)
          else
            f.(:leaf, f)
          end

        {:node, children}, f ->
          children = Enum.shuffle(children)

          from =
            receive do
              {:put, key, values, from} ->
                for child <- children do
                  send(child, {:put, key, values, self()})
                end

                :erlang.yield()
                from

              {:get, key, from} ->
                for child <- children do
                  send(child, {:get, key, self()})
                end

                :erlang.yield()
                from
            end

          values =
            Enum.flat_map(children, fn _ ->
              receive do
                {:reply, reply} -> reply
              end
            end)
            |> Enum.uniq()

          send(from, {:reply, values})

          f.({:node, children}, f)

        :leaf, f ->
          random_sleep = Enum.random(0..3)

          {from, value} =
            receive do
              {:put, key, values, from} when random_sleep > 0 ->
                value = Enum.random(values)
                Process.sleep(random_sleep)
                value = PaxosKV.put(key, value, pid: self())
                :erlang.yield()
                {from, value}

              {:put, key, values, from} ->
                value = Enum.random(values)
                value = PaxosKV.put(key, value, pid: self())
                :erlang.yield()
                {from, value}

              {:get, key, from} ->
                {from, PaxosKV.get(key)}
            end

          send(from, {:reply, [value]})

          f.(:leaf, f)
      end

    fn -> f.({:root, n}, f) end
  end
end
