# Put a real backgammon room into a bearing-off position and leave it in the
# database for the browser to pick up: the player to move has dice on the
# board, a checker or more already off, and may bear off another, and the
# other side has borne off a few too, so both trays have something in them.
#
# It searches seeds with the engine directly (random legal play, no room,
# no clock), then replays exactly those actions through a real room that
# persists them, the way the dance smoke's setup does.
#
#   mix run -e 'Code.eval_file("playwright/test-backgammon-landscape/bearoff.exs")'
#
# The last line printed is one line of JSON: the game id, the seats with the
# guest holding each, and who is bearing off.

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

off = fn instance, player_id ->
  GameKit.player_update(instance, player_id)["scene"]["zones"]
  |> Enum.find(%{"count" => 0}, &(&1["id"] == "off:" <> player_id))
  |> Map.get("count", 0)
end

# The mover may bear off, has 2..8 off, nothing staged yet, and the other
# side has at least one off: both trays show, and there is room to bear off
# a few more without the game ending under the test.
ready? = fn instance, player_id ->
  other = if player_id == "p1", do: "p2", else: "p1"
  update = GameKit.player_update(instance, player_id)
  legal = Enum.map(update["legal"], & &1["name"])

  "bear_off" in legal and "undo" not in legal and off.(instance, player_id) in 2..8 and
    off.(instance, other) in 1..10
end

# Random legal play, never resigning or doubling, until someone is ready.
search = fn seed ->
  {:ok, instance} = GameKit.start("backgammon", "single", seats, seed, :no_clock, 0)
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  Enum.reduce_while(1..3000, {instance, []}, fn _, {instance, taken} ->
    mover = Enum.find(["p1", "p2"], &ready?.(instance, &1))

    cond do
      mover != nil ->
        {:halt, {:ready, mover, Enum.reverse(taken)}}

      GameKit.finished?(instance) ->
        {:halt, :done}

      true ->
        choices =
          for player_id <- ["p1", "p2"],
              schema <- GameKit.player_update(instance, player_id)["legal"],
              schema["name"] not in ["resign", "double"],
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

{seed, mover, actions} =
  Enum.find_value(1..400, fn seed ->
    case search.(seed) do
      {:ready, mover, actions} -> {seed, mover, actions}
      _ -> nil
    end
  end) || raise "no bear-off position found in 400 seeds"

# Now the same game for real, in a room that writes itself down.
game_id = "bearoff-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
{:ok, _} = Game.start_game(game_id, "backgammon")
{:ok, _} = Game.configure(game_id, %{format: "single", clock: "none", seed: seed})
g1 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
g2 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
{:ok, p1, _} = Game.join_game(game_id, "Alice", nil, g1)
{:ok, p2, _} = Game.join_game(game_id, "Bob", nil, g2)
seat_of = %{"p1" => p1, "p2" => p2}

Enum.each(actions, fn {player_id, action} ->
  {:ok, _, _} = Game.player_action(game_id, seat_of[player_id], action)
end)

state = Game.get_server_state(game_id)
legal = GameKit.player_update(state.instance, seat_of[mover])["legal"]
true = "bear_off" in Enum.map(legal, & &1["name"])

:ok = Oskol.Game.Persister.flush()

IO.puts(
  Jason.encode!(%{
    game_id: game_id,
    seed: seed,
    steps: length(actions),
    mover: seat_of[mover],
    players: [
      %{id: p1, name: "Alice", guest: g1},
      %{id: p2, name: "Bob", guest: g2}
    ]
  })
)

