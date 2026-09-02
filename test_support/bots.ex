defmodule Oskol.Bots do
  @moduledoc """
  Random legal-action players for driving rooms in tests.

  A bot reads a player's `legal` schemas from the room and builds a random
  complete action from one of them, so it works for every registered game
  without knowing any rules. A legal action the room rejects is a bug in the
  game or the bridge, and the bot raises on it.
  """

  alias Oskol.Game
  alias Oskol.GameKit

  @doc """
  Play random legal actions in a started room until the game finishes or
  `max_steps` have been played. Returns `{:finished, steps}`,
  `{:cut_off, steps}` or `{:stuck, steps}` (no legal action while unfinished).

  Options: `exclude:` action names never chosen (default `["resign"]`, since
  a random resignation ends every game early and proves nothing).
  """
  def play(game_id, seed, max_steps, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, ["resign"])
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    loop(game_id, max_steps, 0, exclude)
  end

  defp loop(game_id, max, steps, exclude) do
    state = Game.get_server_state(game_id)

    cond do
      GameKit.finished?(state.instance) ->
        {:finished, steps}

      steps >= max ->
        {:cut_off, steps}

      true ->
        choices =
          for player_id <- state.seat_order,
              schema <- GameKit.player_update(state.instance, player_id)["legal"],
              schema["name"] not in exclude,
              do: {player_id, schema}

        case choices do
          [] ->
            {:stuck, steps}

          _ ->
            {player_id, schema} = Enum.random(choices)
            action = action(schema)

            case Game.player_action(game_id, player_id, action) do
              {:ok, _, _} ->
                loop(game_id, max, steps + 1, exclude)

              {:error, reason} ->
                raise "legal action rejected after #{steps} steps: #{player_id} #{inspect(action)}: #{inspect(reason)}"
            end
        end
    end
  end

  @doc "A random complete action for a legal schema."
  def action(schema) do
    params = Map.new(schema["params"], fn param -> {param["name"], value(param)} end)
    %{"name" => schema["name"], "params" => params}
  end

  defp value(%{"type" => "select", "candidates" => candidates, "min" => min, "max" => max}) do
    max = min(max, length(candidates))
    count = if max >= min, do: Enum.random(min..max), else: max
    Enum.take_random(candidates, count)
  end

  defp value(%{"type" => "choice", "options" => options}), do: Enum.random(options)["id"]
  defp value(%{"type" => "number", "min" => min, "max" => max}), do: Enum.random(min..max)
end
