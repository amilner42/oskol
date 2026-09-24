# Shape one account's deck like the one the human hit on their phone, so
# the severity bars can be eyeballed in the state they are drawn for:
# 111 mistakes, 61 of them never started, 50 in progress, none patched
# (patched is level 4, which is weeks away for a deck this young).
#
#   SHAPE_EMAIL=someone@oskol.test mix run -e 'Code.eval_file("playwright/review-puzzles-hub/shape.exs")'
#
# It replaces that account's deck rather than adding to it, so the numbers
# on the shot are exactly the ones named here. Each made-up mistake is a
# copy of a real one of theirs, so every page still renders a real
# question. Screenshots only: it is never run in dev or prod, and it asks
# the engine for nothing.
import Ecto.Query

alias Oskol.Puzzles
alias Oskol.Repo

email = System.get_env("SHAPE_EMAIL") || raise "SHAPE_EMAIL is not set"

# very bad / bad / dubious, each {total, in progress}: 111 mistakes, 50 of
# them in rotation, 61 never started, nothing patched.
shape = [{"very_bad", 61, 30}, {"bad", 35, 15}, {"doubtful", 15, 5}]

user = Repo.get_by!(Oskol.Auth.User, email: email)
{:ok, deck} = Retain.fetch_user(user.id)

# One real card of theirs, and the puzzle and source rows behind it: what
# every copy is made from, so a page has a real question to draw.
sample = Repo.one!(from(i in Retain.Item, where: i.user_id == ^deck.id, limit: 1))
puzzle = Repo.get!(Puzzles.Puzzle, sample.key)
source = Repo.one!(from(s in Puzzles.Source, where: s.puzzle_id == ^sample.key, limit: 1))

now = DateTime.utc_now()

rows =
  shape
  |> Enum.flat_map(fn {grade, total, _going} ->
    Enum.map(1..total, fn n -> {"shape-#{grade}-#{n}", grade} end)
  end)
  # A turn nothing else in that game can have: the sources table is one
  # row per (game, game number, turn, kind).
  |> Enum.with_index(1000)

Repo.insert_all(
  Puzzles.Puzzle,
  Enum.map(rows, fn {{key, _grade}, _turn} ->
    %{
      id: key,
      key: key,
      kind: puzzle.kind,
      question: puzzle.question,
      answer: puzzle.answer,
      evaluated_by: puzzle.evaluated_by,
      complete: puzzle.complete,
      inserted_at: now,
      updated_at: now
    }
  end),
  on_conflict: :nothing
)

Repo.insert_all(
  Puzzles.Source,
  Enum.map(rows, fn {{key, grade}, turn} ->
    %{
      puzzle_id: key,
      game_id: source.game_id,
      game_number: source.game_number,
      turn: turn,
      kind: source.kind,
      seat: source.seat,
      player_id: source.player_id,
      played: source.played,
      equity_lost: 0.2,
      grade: grade,
      owner_user_id: user.id,
      deck_synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end),
  on_conflict: :nothing
)

Repo.delete_all(from(i in Retain.Item, where: i.user_id == ^deck.id))

{:ok, _} =
  Retain.put_items(
    user.id,
    Enum.map(rows, fn {{key, _grade}, _turn} ->
      %{key: key, tags: sample.tags, content: sample.content}
    end)
  )

started =
  shape
  |> Enum.flat_map(fn {grade, _total, going} ->
    case going do
      0 -> []
      _ -> Enum.map(1..going, fn n -> "shape-#{grade}-#{n}" end)
    end
  end)

{:ok, _} = Retain.start(user.id, started)

IO.puts(
  Jason.encode!(%{
    total: length(rows),
    in_progress: length(started),
    untouched: length(rows) - length(started),
    patched: 0
  })
)
