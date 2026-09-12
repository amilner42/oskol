# Put a real backgammon room into a danced state and leave it in the
# database for the browser to pick up.
#
# A dance (a roll with no legal move) needs a blocked board, which takes a
# few dozen turns to arrange, so this searches seeds with the engine
# directly -- fast, no room, no clock -- and then replays exactly the
# actions it found through a real room, which persists them. The web server
# rehydrates that room from the log when the browser opens it, which is also
# the proof that a game saved mid-dance reloads sanely.
#
#   mix run -e 'Code.eval_file("playwright/test-backgammon-dance/setup.exs")'
#
# Prints one line of JSON: the game id, the seats and their tokens, and who
# is the one dancing.

alias Oskol.Game
alias Oskol.Game.GameServerState
alias Oskol.GameKit

seats = [{"p1", "Alice"}, {"p2", "Bob"}]

# A complete action for a legal schema (the same thing Oskol.Bots does, which
# lives in test support and is not compiled here).
value = fn
  %{"type" => "choice", "options" => options} -> Enum.random(options)["id"]
  %{"type" => "number", "min" => min, "max" => max} -> Enum.random(min..max)
  %{"type" => "select", "candidates" => candidates, "min" => min} -> Enum.take_random(candidates, min)
end

action_for = fn schema ->
  %{"name" => schema["name"], "params" => Map.new(schema["params"], &{&1["name"], value.(&1)})}
end

# Everyone's scene says `no_moves`; the dancer is the player to move.
dancing? = fn instance, player_id ->
  data = GameKit.player_update(instance, player_id)["scene"]["data"]
  data["no_moves"] == true and data["to_move"] == player_id
end

# Random legal play, never resigning, stopping the moment someone dances.
search = fn seed ->
  {:ok, instance} = GameKit.start("backgammon", "single", seats, seed, :no_clock, 0)
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  Enum.reduce_while(1..2000, {instance, []}, fn _, {instance, taken} ->
    danced = Enum.find(["p1", "p2"], &dancing?.(instance, &1))

    cond do
      danced != nil ->
        {:halt, {:danced, danced, Enum.reverse(taken)}}

      GameKit.finished?(instance) ->
        {:halt, :done}

      true ->
        choices =
          for player_id <- ["p1", "p2"],
              schema <- GameKit.player_update(instance, player_id)["legal"],
              schema["name"] != "resign",
              do: {player_id, schema}

        case choices do
          [] ->
            {:halt, :done}

          _ ->
            {player_id, schema} = Enum.random(choices)
            action = action_for.(schema)
            {:ok, next, _} = GameKit.apply(instance, player_id, action, 0)
            {:cont, {next, [{player_id, action} | taken]}}
        end
    end
  end)
end

{seed, dancer, actions} =
  Enum.find_value(1..400, fn seed ->
    case search.(seed) do
      {:danced, dancer, actions} -> {seed, dancer, actions}
      _ -> nil
    end
  end) || raise "no dance found in 400 seeds"

# Now the same game for real, in a room that writes itself down.
game_id = "dance-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
{:ok, _} = Game.start_game(game_id, "backgammon")
{:ok, _} = Game.configure(game_id, %{format: "single", clock: "none", seed: seed})
{:ok, p1, _} = Game.join_game(game_id, "Alice", nil)
{:ok, p2, state} = Game.join_game(game_id, "Bob", nil)

# The room's seat ids are not "p1"/"p2": map the search's ids onto them in
# seat order, which is the order the players joined.
seat_of = %{"p1" => p1, "p2" => p2}

Enum.each(actions, fn {player_id, action} ->
  {:ok, _, _} = Game.player_action(game_id, seat_of[player_id], action)
end)

state = Game.get_server_state(game_id)
true = GameKit.player_update(state.instance, seat_of[dancer])["scene"]["data"]["no_moves"]

# Let the write-behind catch up before this node goes away.
Process.sleep(1500)

IO.puts(
  Jason.encode!(%{
    game_id: game_id,
    seed: seed,
    steps: length(actions),
    dancer: seat_of[dancer],
    players: [
      %{id: p1, name: "Alice", token: GameServerState.token_for(state, p1)},
      %{id: p2, name: "Bob", token: GameServerState.token_for(state, p2)}
    ]
  })
)
