# A finished match to 3 of more than one game, played into a real room and
# left in the database for the replay page to open.
#
# The match is found by random legal play against the engine (fast, no
# room, no clock), then exactly those actions are replayed through a real
# room, which persists them; the server rehydrates it from the log when the
# page asks for its record.
#
#   mix run -e 'Code.eval_file("playwright/test-backgammon-replay/setup.exs")'
#
# Prints one line of JSON: the game id, the seats and the guest holding each.

# The last line of this script's output is its result, read by the smoke
# that ran it. Ecto logs every query at debug on the same stream, and a
# write that lands after the result would be mistaken for it.
Logger.configure(level: :warning)

alias Oskol.Game
alias Oskol.GameKit

seats = [{"p1", "Alice"}, {"p2", "Bob"}]

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

games_played = fn instance ->
  length(GameKit.player_update(instance, "p1")["scene"]["data"]["games"])
end

# Random legal play, never resigning, to the end of the match.
search = fn seed ->
  {:ok, instance} = GameKit.start("backgammon", "match3", seats, seed, :no_clock, 0)
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  Enum.reduce_while(1..4000, {instance, []}, fn _, {instance, taken} ->
    if GameKit.finished?(instance) do
      {:halt, {:finished, games_played.(instance), Enum.reverse(taken)}}
    else
      choices =
        for player_id <- ["p1", "p2"],
            schema <- GameKit.player_update(instance, player_id)["legal"],
            schema["name"] != "resign",
            do: {player_id, schema}

      case choices do
        [] ->
          {:halt, :stuck}

        _ ->
          {player_id, schema} = Enum.random(choices)
          action = action_for.(schema)
          {:ok, next, _} = GameKit.apply(instance, player_id, action, 0)
          {:cont, {next, [{player_id, action} | taken]}}
      end
    end
  end)
end

{seed, actions} =
  Enum.find_value(1..300, fn seed ->
    case search.(seed) do
      {:finished, games, actions} when games > 1 -> {seed, actions}
      _ -> nil
    end
  end) || raise "no finished match of several games in 300 seeds"

game_id = "replay-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
{:ok, _} = Game.start_game(game_id, "backgammon")
{:ok, _} = Game.configure(game_id, %{format: "match3", clock: "none", seed: seed})
# A seat is held by the guest that took it, so the room is seeded with a
# guest per seat and the browser is handed that cookie.
g1 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
g2 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
{:ok, p1, _} = Game.join_game(game_id, "Alice", nil, g1)
{:ok, p2, _} = Game.join_game(game_id, "Bob", nil, g2)
seat_of = %{"p1" => p1, "p2" => p2}

Enum.each(actions, fn {player_id, action} ->
  {:ok, _, _} = Game.player_action(game_id, seat_of[player_id], action)
end)

state = Game.get_server_state(game_id)
true = GameKit.finished?(state.instance)

# Wait for the write-behind to land before this node goes away: the browser
# reaches a server that rebuilds the room from the log.
:ok = Oskol.Game.Persister.flush()

IO.puts(
  Jason.encode!(%{
    game_id: game_id,
    seed: seed,
    steps: length(actions),
    players: [
      %{id: p1, name: "Alice", guest: g1},
      %{id: p2, name: "Bob", guest: g2}
    ]
  })
)
