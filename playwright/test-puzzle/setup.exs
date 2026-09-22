# A finished backgammon game, graded against a stubbed engine, with its
# mistakes written as puzzles: what the puzzle smoke opens.
#
# The game is found by random legal play against the engine (no room, no
# clock), replayed through a real room so it is persisted like any other,
# and then reviewed here, in this VM, against an engine answered by a
# `Req.Test` plug: for every turn the plug works out the legal plays with
# the same Gleam the page's tree comes from, calls one of them best and the
# one played a mistake, so extraction writes real puzzles from real
# positions. No network, and nothing the server's own queue has to do.
#
#   mix run -e 'Code.eval_file("playwright/test-puzzle/setup.exs")'
#
# Prints one line of JSON: the room, its seats and the guest holding each,
# and the first checker-play puzzle of each seat (id, turn, what was
# played), plus a cube puzzle seeded from the fixtures for the scale.

# The last line of this script's output is its result, read by the smoke
# that ran it; Ecto logs every query at debug on the same stream.
Logger.configure(level: :warning)

import Ecto.Query, only: [from: 2]

alias Oskol.Game
alias Oskol.GameKit

# The server's queue is not this VM's: this script reviews the game itself,
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

# One turn's verdict. The play made is the best on every third turn and a
# mistake otherwise (bad, or doubtful on every other one), so the game has
# both puzzles and turns that are none.
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
          cond do
            rem(i, 3) == 0 -> 0.0
            rem(i, 2) == 0 -> 0.05
            true -> 0.11
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

# ---------- the game ----------

seats = [{"p1", "Alice"}, {"p2", "Bob"}]

value = fn
  %{"type" => "choice", "options" => options} -> Enum.random(options)["id"]
  %{"type" => "number", "min" => min, "max" => max} -> Enum.random(min..max)
  %{"type" => "select", "candidates" => candidates, "min" => min} -> Enum.take_random(candidates, min)
end

action_for = fn schema ->
  %{"name" => schema["name"], "params" => Map.new(schema["params"], &{&1["name"], value.(&1)})}
end

# Random legal play, never resigning and never touching the cube, to the
# end of a single game: a game of checker plays only, so every puzzle is
# one the board can be asked.
search = fn seed ->
  {:ok, instance} = GameKit.start("backgammon", "single", seats, seed, :no_clock, 0)
  :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  Enum.reduce_while(1..2000, {instance, []}, fn _, {instance, taken} ->
    if GameKit.finished?(instance) do
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

{seed, actions} =
  Enum.find_value(1..200, fn seed ->
    case search.(seed) do
      {:finished, actions} when length(actions) > 40 -> {seed, actions}
      _ -> nil
    end
  end) || raise "no finished game in 200 seeds"

game_id = "puzzle-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
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
true = GameKit.finished?(state.instance)
:ok = Oskol.Game.Persister.flush()

# ---------- the review, and the puzzles it writes ----------

:ok = Oskol.Reviews.Queue.run(game_id)

[%{status: "done"}] = Oskol.Reviews.stored(game_id)

sources =
  Oskol.Repo.all(
    from(s in Oskol.Puzzles.Source,
      where: s.game_id == ^game_id and not is_nil(s.puzzle_id),
      order_by: s.turn
    )
  )

first_of = fn player_id ->
  case Enum.find(sources, &(&1.player_id == player_id and &1.kind == "move")) do
    nil -> nil
    s -> %{id: s.puzzle_id, turn: s.turn, played: s.played, grade: s.grade, equity_lost: s.equity_lost}
  end
end

# A cube question, from the fixtures, for the five-band scale. Not a source
# of this game: a scale has nothing to do with the game's own mistakes.
{:stored, _, kind, question, answer} = :oskol@puzzles@fixture.stored_sample("double")
cube_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

Oskol.Repo.insert!(%Oskol.Puzzles.Puzzle{
  id: cube_id,
  key: "smoke-" <> cube_id,
  kind: kind,
  question: Jason.decode!(question),
  answer: Jason.decode!(answer),
  evaluated_by: %{}
})

IO.puts(
  Jason.encode!(%{
    game_id: game_id,
    seed: seed,
    puzzles: length(sources),
    players: [
      %{id: p1, name: "Alice", guest: g1, puzzle: first_of.(p1)},
      %{id: p2, name: "Bob", guest: g2, puzzle: first_of.(p2)}
    ],
    cube: cube_id
  })
)
