# Two finished backgammon rooms, graded against a stubbed engine, with their
# mistakes written as puzzles: what the result cards' PRACTICE opens.
#
#  - `unlimited`: an unlimited session with two games played to the end,
#    the second of them just over -- so its table shows the between-games
#    card, nobody on the clock, READY not yet pressed.
#  - `single`: one game played to the end -- the game-over card.
#
# The same two guests hold p1 and p2 in both, so a sign-in on one table
# brings both games along. Each game is found by random legal play against
# the engine (no room, no clock), replayed through a real room so it is
# persisted like any other, and reviewed here, in this VM, against an
# engine answered by a `Req.Test` plug that calls a third of the plays best
# and the rest mistakes (test-puzzle/setup.exs is where that plug comes
# from; this script uses the same rule). No network, and nothing the
# server's own queue has to do.
#
#   mix run -e 'Code.eval_file("playwright/test-puzzles-cards/setup.exs")'
#
# Prints one line of JSON: the two rooms, each with the count of puzzles
# per seat per game, and the two seats with the guest holding each.

# The last line of this script's output is its result, read by the smoke
# that ran it; Ecto logs every query at debug on the same stream.
Logger.configure(level: :warning)

import Ecto.Query, only: [from: 2]

alias Oskol.Game
alias Oskol.GameKit

# The server's queue is not this VM's: this script reviews the games itself,
# synchronously, so nothing here races a job it did not start.
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

# ---------- the engine ----------

Req.Test.set_req_test_to_shared()

analysis = Application.get_env(:oskol, :analysis, [])

Application.put_env(
  :oskol,
  :analysis,
  Keyword.merge(analysis, req_options: [plug: {Req.Test, Oskol.Reviews}])
)

probs = %{
  "win" => 0.52,
  "gammon_win" => 0.11,
  "backgammon_win" => 0.01,
  "gammon_loss" => 0.09,
  "backgammon_loss" => 0.01
}

# Every legal way to play the roll from this board, as {board, notation}:
# the terminals of the same tree the page walks, each named by the path
# that reaches it.
legal_plays = fn board, [a, b] ->
  {:ok, start} = :oskol@puzzles@tree.from_engine(board)
  {:ok, {:tree, root, nodes, _lazy}} = :oskol@puzzles@tree.build(start, :oskol@puzzles@tree.dice_of({a, b}), 100_000)
  by_id = Map.new(nodes, fn {:node, id, _, _, _, _} = n -> {id, n} end)

  walk = fn walk, id, path ->
    {:node, _, node_board, _, _, children} = Map.fetch!(by_id, id)

    case children do
      [] ->
        [{:backgammon@analysis.encode(node_board, :white), Enum.reverse(path) |> Enum.join(" ")}]

      _ ->
        Enum.flat_map(children, fn {:child, _die, from, to, next} ->
          step = :backgammon@board.loc_id(from) <> "/" <> :backgammon@board.loc_id(to)
          walk.(walk, next, [step | path])
        end)
    end
  end

  walk.(walk, root, [])
  |> Enum.uniq_by(fn {b, _} -> b end)
end

# One turn's verdict. A third of the plays are mistakes (bad, or doubtful
# on every other one) and the rest the best, so the game has both puzzles
# and turns that are none, and a run of a game's mistakes is a dozen or
# so, which a smoke can play through.
grade_turn = fn turn, i ->
  case turn do
    %{"dice" => [_, _] = dice, "played" => played} when is_list(played) ->
      plays = legal_plays.(turn["board"], dice)
      n_legal = length(plays)
      danced = plays == [] or played == turn["board"]

      if danced or n_legal < 2 do
        %{"danced" => true}
      else
        {played_board, played_notation} =
          Enum.find(plays, {played, "?"}, fn {b, _} -> b == played end)

        {best_board, best_notation} = Enum.find(plays, fn {b, _} -> b != played_board end)

        lost =
          case rem(i, 6) do
            1 -> 0.11
            4 -> 0.05
            _ -> 0.0
          end

        grade =
          cond do
            lost == 0.0 -> "best"
            lost < 0.08 -> "doubtful"
            true -> "bad"
          end

        {best_board, best_notation} =
          if lost == 0.0, do: {played_board, played_notation}, else: {best_board, best_notation}

        candidate = fn rank, board, notation, diff ->
          %{
            "rank" => rank,
            "notation" => notation,
            "board" => board,
            "equity" => 0.12 + diff,
            "cubeless_equity" => 0.12 + diff,
            "equity_diff" => diff,
            "probs" => probs
          }
        end

        others =
          plays
          |> Enum.reject(fn {b, _} -> b == played_board or b == best_board end)
          |> Enum.with_index(1)
          |> Enum.map(fn {{b, n}, k} -> {b, n, -0.02 - 0.03 * k} end)

        ranked =
          [{best_board, best_notation, 0.0}] ++
            if(lost == 0.0, do: [], else: [{played_board, played_notation, -lost}]) ++ others

        ranked = Enum.sort_by(ranked, fn {_, _, d} -> -d end)

        candidates =
          ranked
          |> Enum.with_index(1)
          |> Enum.map(fn {{b, n, d}, rank} -> candidate.(rank, b, n, d) end)

        played_c = Enum.find(candidates, &(&1["board"] == played_board))

        %{
          "played" => played_c,
          "best" => hd(candidates),
          "top" => Enum.take(candidates, 5),
          "results" => Enum.map(ranked, fn {b, _, d} -> %{"board" => b, "equity_diff" => d} end),
          "n_legal" => n_legal,
          "forced" => false,
          "error" => lost,
          "grade" => grade
        }
      end

    _ ->
      nil
  end
end

Req.Test.stub(Oskol.Reviews, fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
  request = Jason.decode!(body)

  turns =
    request["turns"]
    |> Enum.with_index()
    |> Enum.map(fn {turn, i} ->
      %{"index" => i, "cube" => nil, "move" => grade_turn.(turn, i), "luck" => %{"luck" => 0.02}}
    end)

  n = length(turns)

  totals = %{
    "moves" => %{"decisions" => n, "forced" => 0, "error" => 0.1, "grades" => %{"ok" => n}},
    "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
    "luck" => 0.0,
    "error" => 0.1,
    "pr" => 6.1
  }

  Req.Test.json(conn, %{
    "levels" => %{"moves" => "4ply", "cube" => "4ply"},
    "timing_ms" => 1200,
    "turns" => turns,
    "players" => [totals, totals]
  })
end)

# ---------- the games ----------

seats = [{"p1", "Alice"}, {"p2", "Bob"}]

value = fn
  %{"type" => "choice", "options" => options} -> Enum.random(options)["id"]
  %{"type" => "number", "min" => min, "max" => max} -> Enum.random(min..max)
  %{"type" => "select", "candidates" => candidates, "min" => min} -> Enum.take_random(candidates, min)
end

action_for = fn schema ->
  %{"name" => schema["name"], "params" => Map.new(schema["params"], &{&1["name"], value.(&1)})}
end

# Random legal play, never resigning and never touching the cube (a game of
# checker plays only, so every puzzle is one the board can be asked), until
# `done?` says the room is where the smoke wants it. READY is legal play
# like any other, so unlimited play goes on into its next game on its own.
search = fn seed, format, done? ->
  {:ok, instance} = GameKit.start("backgammon", format, seats, seed, :no_clock, 0)
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  Enum.reduce_while(1..4000, {instance, []}, fn _, {instance, taken} ->
    if done?.(instance) do
      {:halt, {:finished, Enum.reverse(taken)}}
    else
      choices =
        for player_id <- ["p1", "p2"],
            schema <- GameKit.player_update(instance, player_id)["legal"],
            schema["name"] not in ["resign", "double"],
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

# Where the game on the board stands, by the spectator's scene: its phase
# and its number.
where = fn instance ->
  scene = GameKit.spectator_update(instance)["scene"]
  {scene["phase"], scene["data"]["game_number"]}
end

# The single game: over.
single_done? = fn instance -> GameKit.finished?(instance) end

# Unlimited play: the second game just over, READY not yet pressed by
# anyone (random play stops the moment the phase is reached).
unlimited_done? = fn instance -> where.(instance) == {"between_games", 2} end

find = fn format, done?, min_actions ->
  Enum.find_value(1..300, fn seed ->
    case search.(seed, format, done?) do
      {:finished, actions} when length(actions) > min_actions -> {seed, actions}
      _ -> nil
    end
  end) || raise "no #{format} room in 300 seeds"
end

g1 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
g2 = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

arrange = fn format, done?, min_actions ->
  {seed, actions} = find.(format, done?, min_actions)
  game_id = "cards-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  {:ok, _} = Game.start_game(game_id, "backgammon")
  {:ok, _} = Game.configure(game_id, %{format: format, clock: "none", seed: seed})
  {:ok, p1, _} = Game.join_game(game_id, "Alice", nil, g1)
  {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, g2)
  seat_of = %{"p1" => p1, "p2" => p2}

  Enum.each(actions, fn {player_id, action} ->
    {:ok, _, _} = Game.player_action(game_id, seat_of[player_id], action)
  end)

  :ok = Oskol.Game.Persister.flush()

  # ---------- the review, and the puzzles it writes ----------

  :ok = Oskol.Reviews.Queue.run(game_id)
  stored = Oskol.Reviews.stored(game_id)
  true = Enum.all?(stored, &(&1.status == "done"))

  counts =
    Oskol.Repo.all(
      from(s in Oskol.Puzzles.Source,
        where: s.game_id == ^game_id and not is_nil(s.puzzle_id),
        group_by: [s.game_number, s.player_id],
        select: {s.game_number, s.player_id, count(s.id)}
      )
    )
    |> Enum.group_by(fn {n, _, _} -> n end, fn {_, pid, c} -> {pid, c} end)
    |> Map.new(fn {n, per_seat} -> {n, Map.new(per_seat)} end)

  %{game_id: game_id, seed: seed, games: length(stored), counts: counts, seats: seat_of}
end

unlimited = arrange.("unlimited", unlimited_done?, 60)
single = arrange.("single", single_done?, 40)

# The second game of unlimited play must have left each seat a mistake to
# practice, or the smoke has nothing to open; a third of the plays being
# mistakes makes that a near certainty, and this says so when it is not.
true = map_size(Map.get(unlimited.counts, 2, %{})) == 2
true = map_size(Map.get(single.counts, 1, %{})) == 2

IO.puts(
  Jason.encode!(%{
    unlimited: unlimited,
    single: single,
    players: [
      %{id: "p1", name: "Alice", guest: g1},
      %{id: "p2", name: "Bob", guest: g2}
    ]
  })
)
