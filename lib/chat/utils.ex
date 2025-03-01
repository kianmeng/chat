defmodule Chat.Utils do
  @moduledoc "Util functions"

  def page(timestamped, before, amount) do
    timestamped
    |> Enum.reduce_while({[], nil, amount}, fn
      %{timestamp: last_timestamp} = msg, {acc, last_timestamp, amount} ->
        {:cont, {[msg | acc], last_timestamp, amount - 1}}

      _, {_, _, amount} = acc when amount < 1 ->
        {:halt, acc}

      %{timestamp: timestamp} = msg, {acc, _, amount} when timestamp < before ->
        {:cont, {[msg | acc], timestamp, amount - 1}}

      _, acc ->
        {:cont, acc}
    end)
    |> then(&elem(&1, 0))
  end
end
