# The room SHARE POSITION is tried on: the seeded match at 821900, a real
# match graded by the real engine (`Oskol.Dev.RoomImport`), put back as it
# was and with every stored checker play given every legal play -- what an
# answer from today's engine carries (the seeded ones predate
# `all_results`, and a share refuses an answer short of them). The plays
# the engine described keep its costs; the rest are made up, a little worse
# than the worst it described. Also drops any puzzle a previous run shared
# from it, so the run starts clean.
#
#   mix run -e 'Code.eval_file("playwright/test-backgammon-replay/share_setup.exs")'
import Ecto.Query

alias Oskol.Repo
alias Oskol.Reviews.{Record, Review}

code = "821900"
:ok = Oskol.Dev.RoomImport.import!(code)

Repo.delete_all(from(p in Oskol.Puzzles.Puzzle, where: fragment("?->>'id'", p.replay) == ^code))

order =
  Repo.one!(from(g in Oskol.Persistence.Game, where: g.id == ^code, select: g.players))
  |> Enum.map(& &1["id"])

# Every legal way to play `dice` from the mover's engine board.
legal = fn board, {a, b} ->
  {:ok, start} = :oskol@puzzles@tree.from_engine(board)

  {:ok, {:tree, root, nodes, _lazy}} =
    :oskol@puzzles@tree.build(start, :oskol@puzzles@tree.dice_of({a, b}), 100_000)

  by_id = Map.new(nodes, fn {:node, id, _, _, _, _} = n -> {id, n} end)

  walk = fn walk, id ->
    {:node, _, node_board, _, _, children} = Map.fetch!(by_id, id)

    case children do
      [] -> [:backgammon@analysis.encode(node_board, :white)]
      _ -> Enum.flat_map(children, fn {:child, _die, _from, _to, next} -> walk.(walk, next) end)
    end
  end

  walk.(walk, root) |> Enum.uniq()
end

for review <- Repo.all(from(r in Review, where: r.game_id == ^code)) do
  record =
    Repo.one!(
      from(r in Record, where: r.game_id == ^code and r.game_number == ^review.game_number)
    )

  {:ok, entries} =
    :gleam@json.parse(Jason.encode!(record.entries), :gleam@dynamic@decode.list(:backgammon@record.decoder()))

  turns = :backgammon@analysis.turns_from_record(entries, order, 0, [], false)

  graded =
    Enum.zip(review.response["turns"], turns)
    |> Enum.map(fn
      {%{"move" => %{"n_legal" => n, "top" => top, "played" => played} = move} = turn,
       {:turn, _, _, {:position, board, _, _, _, _, _}, _, {:some, dice}, _, _, _, _, _}}
      when is_integer(n) and n > 0 ->
        known = Map.new([played | top], &{&1["board"], &1["equity_diff"]})
        worst = known |> Map.values() |> Enum.min()

        results =
          legal.(board, dice)
          |> Enum.map(&%{"board" => &1, "equity_diff" => Map.get(known, &1, worst - 0.05)})

        %{turn | "move" => Map.merge(move, %{"results" => results, "n_legal" => length(results)})}

      {turn, _} ->
        turn
    end)

  review
  |> Ecto.Changeset.change(response: %{review.response | "turns" => graded})
  |> Repo.update!()
end

IO.puts(Jason.encode!(%{game_id: code}))
