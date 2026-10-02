defmodule Oskol.CompleteEngine do
  @moduledoc """
  A stand-in for the analysis engine that answers a checker play the way the
  real one does with `all_results`: every legal play of the roll, each with
  the board it leaves and what it gives up, the top five in full. The legal
  plays are the terminals of the same tree the puzzle page walks
  (`oskol/puzzles/tree`), so what it grades is exactly what a player can
  play.

  The first legal play is called best and each later one a little worse, so
  answers are deterministic. It echoes each turn's `index`, as the engine
  does. Plug it in with `Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)`.

  `prefer:` names plays to rank first when they are legal (the opening 3-1's
  `8/5 6/5`), so a smoke can read a sensible best play off the answer; the
  rest keep the tree's order.
  """

  @probs %{
    "win" => 0.52,
    "gammon_win" => 0.14,
    "backgammon_win" => 0.01,
    "gammon_loss" => 0.12,
    "backgammon_loss" => 0.01
  }

  def respond(conn, opts \\ []) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
    asked = Jason.decode!(body)

    case conn.request_path do
      "/backgammon/rolls" ->
        Req.Test.json(conn, grid(asked))

      "/backgammon/batch" ->
        results = Enum.map(asked["items"], fn item -> grid(item["request"]) end)
        Req.Test.json(conn, %{"results" => results})

      _ ->
        Req.Test.json(conn, answer(asked, opts))
    end
  end

  @doc """
  One board's per-roll grid, the shape `POST /backgammon/rolls` answers and
  `rolls: true` puts on a turn: 21 rows, `a <= b`, doubles first, weight 1 for
  a double and 2 otherwise.

  The equities are made up but the invariant is not: the top-level equity is
  the rows' weighted mean, which is what the page and `oskol/analysis/rolls`
  lean on. 6-6 is the best roll here, so a test can check a sign.
  """
  def grid(_request) do
    rows =
      for [d1, d2] <- dice_pairs() do
        %{
          "dice" => [d1, d2],
          "weight" => if(d1 == d2, do: 1, else: 2),
          "equity" => (d1 + d2) / 100.0 - 0.07,
          "best" => "#{13 - d1}/#{13 - d1 - d2}"
        }
      end

    total = Enum.reduce(rows, 0.0, fn row, sum -> sum + row["weight"] * row["equity"] end)

    %{"level" => "3ply", "equity" => total / 36.0, "rows" => rows}
  end

  defp dice_pairs do
    doubles = for d <- 1..6, do: [d, d]
    rest = for low <- 1..5, high <- (low + 1)..6, do: [low, high]
    doubles ++ rest
  end

  @doc "The engine's answer to a decoded review request, as a map."
  def answer(request, opts \\ []) do
    prefer = Keyword.get(opts, :prefer, [])

    turns =
      request["turns"]
      |> Enum.with_index()
      |> Enum.map(fn {turn, at} ->
        %{
          "index" => turn["index"] || at,
          "player" => turn["player"] || 0,
          "cube" => cube(turn),
          "move" => move(turn, prefer),
          "luck" => %{"luck" => 0.0}
        }
        |> grid_if_asked(request, turn)
      end)

    n = length(turns)

    totals = %{
      "moves" => %{"decisions" => n, "forced" => 0, "error" => 0.0, "grades" => %{"best" => n}},
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.0,
      "error" => 0.0,
      "pr" => 0.0
    }

    %{
      "levels" => %{"moves" => "4ply", "cube" => "4ply"},
      "timing_ms" => 10,
      "turns" => turns,
      "players" => [totals, totals]
    }
  end

  # The engine puts a grid on every turn when the request asks for one, and on
  # no turn when it does not -- which is what the review path relies on.
  defp grid_if_asked(out, request, turn) do
    if request["rolls"], do: Map.put(out, "rolls", grid(turn)), else: out
  end

  defp move(%{"board" => board, "dice" => [_, _] = dice, "played" => played}, prefer) do
    {preferred, rest} =
      legal_plays(board, dice) |> Enum.split_with(fn {_, notation} -> notation in prefer end)

    plays = preferred ++ rest

    ranked =
      plays
      |> Enum.with_index()
      |> Enum.map(fn {{b, notation}, k} ->
        {b, notation, if(k == 0, do: 0.0, else: -0.02 * k)}
      end)

    candidates =
      ranked
      |> Enum.with_index(1)
      |> Enum.map(fn {{b, notation, diff}, rank} ->
        %{
          "rank" => rank,
          "notation" => notation,
          "board" => b,
          "equity" => 0.05 + diff,
          "cubeless_equity" => 0.05 + diff,
          "equity_diff" => diff,
          "probs" => @probs
        }
      end)

    played_c = Enum.find(candidates, hd(candidates), &(&1["board"] == played))

    %{
      "played" => played_c,
      "best" => hd(candidates),
      "top" => Enum.take(candidates, 5),
      "results" => Enum.map(ranked, fn {b, _, d} -> %{"board" => b, "equity_diff" => d} end),
      "n_legal" => length(plays),
      "forced" => length(plays) == 1,
      "error" => -played_c["equity_diff"],
      "grade" => "best"
    }
  end

  defp move(_, _), do: nil

  # A turn with no dice is a cube question on its own (the analysis board's
  # "Double?" or "Take?"): the engine's verdict, a clear double and pass,
  # with the chances it was judged on. A game's turns always roll, and their
  # cube stays unjudged here as before.
  defp cube(%{"dice" => dice}) when dice in [nil, []] do
    %{
      "action" => "no_double",
      "optimal" => "double_pass",
      "analysis" => %{
        "optimal_action" => "double_pass",
        "equity_nd" => 0.62,
        "equity_dt" => 1.31,
        "equity_dp" => 1.0,
        "probs" => @probs
      },
      "doubler" => %{"error" => 0.38, "grade" => "very_bad"}
    }
  end

  defp cube(_), do: nil

  @doc "Every legal way to play `dice` from `board`, as {board, notation}."
  def legal_plays(board, [a, b]) do
    {:ok, start} = :oskol@puzzles@tree.from_engine(board)

    {:ok, {:tree, root, nodes, _lazy}} =
      :oskol@puzzles@tree.build(start, :oskol@puzzles@tree.dice_of({a, b}), 100_000)

    by_id = Map.new(nodes, fn {:node, id, _, _, _, _} = n -> {id, n} end)

    walk = fn walk, id, path ->
      {:node, _, node_board, _, _, children} = Map.fetch!(by_id, id)

      case children do
        [] ->
          [
            {:backgammon@analysis.encode(node_board, :white),
             path |> Enum.reverse() |> Enum.join(" ")}
          ]

        _ ->
          Enum.flat_map(children, fn {:child, _die, from, to, next} ->
            step = :backgammon@board.loc_id(from) <> "/" <> :backgammon@board.loc_id(to)
            walk.(walk, next, [step | path])
          end)
      end
    end

    walk.(walk, root, []) |> Enum.uniq_by(fn {b, _} -> b end)
  end
end
