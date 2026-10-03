# A match to 5 against Sage, left at the start of the person's turn with
# DOUBLE on offer, in the database for the browser to pick up.
#
# Sage is a bot seat, and a bot asks the engine; a smoke spends no engine
# time, so nothing answers it here and it never moves by itself. This plays
# both seats with random legal actions instead -- the same thing a bot task
# would apply, through the same room -- until the person may double, and
# flushes the log so the web server rehydrates the room exactly there.
#
#   mix run -e 'Code.eval_file("playwright/test-cube-hold/setup.exs")'
#
# Prints one line of JSON: the game id and the person's seat and guest.

# The last line of this script's output is its result, read by the smoke
# that ran it. Ecto logs every query at debug on the same stream.
Logger.configure(level: :error)

alias Oskol.Game
alias Oskol.GameKit

value = fn
  %{"type" => "choice", "options" => options} ->
    Enum.random(options)["id"]

  %{"type" => "number", "min" => min, "max" => max} ->
    Enum.random(min..max)

  %{"type" => "select", "candidates" => candidates, "min" => min} ->
    Enum.take_random(candidates, min)
end

action_for = fn schema ->
  %{"name" => schema["name"], "params" => Map.new(schema["params"], &{&1["name"], value.(&1)})}
end

:rand.seed(:exsss, {7, 11, 13})

game_id = "cubehold-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
{:ok, _} = Game.start_game(game_id, "backgammon")
{:ok, _} = Game.configure(game_id, %{format: "match5", clock: "none", seed: 4242})
guest = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
{:ok, me, _} = Game.join_game(game_id, "Alice", nil, guest)
{:ok, sage, _} = Game.join_bot(game_id, "Sage")

legal = fn player_id ->
  state = Game.get_server_state(game_id)
  GameKit.player_update(state.instance, player_id)["legal"]
end

may_double? = fn -> Enum.any?(legal.(me), &(&1["name"] == "double")) end

# Moves and rolls only: nobody doubles, resigns or passes a cube on the way.
playable = fn player_id ->
  legal.(player_id)
  |> Enum.reject(&(&1["name"] in ["resign", "double", "accept_resign", "decline_resign"]))
end

:ok =
  Enum.reduce_while(1..400, :playing, fn _, _ ->
    if may_double?.() do
      {:halt, :ok}
    else
      case Enum.flat_map([me, sage], fn p -> Enum.map(playable.(p), &{p, &1}) end) do
        [] ->
          {:halt, :stuck}

        choices ->
          {player_id, schema} = Enum.random(choices)
          {:ok, _, _} = Game.player_action(game_id, player_id, action_for.(schema))
          {:cont, :playing}
      end
    end
  end)

:ok = Oskol.Game.Persister.flush()

IO.puts(Jason.encode!(%{game_id: game_id, me: me, sage: sage, guest: guest}))
