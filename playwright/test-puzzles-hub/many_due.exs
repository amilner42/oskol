# Give an account more very bad moves due today than one page of a session
# holds, so a run through them has to ask its queue again to get past the
# twentieth:
#
#   SHAPE_EMAIL=... DUE_COUNT=25 mix run -e 'Code.eval_file("playwright/test-puzzles-hub/many_due.exs")'
#
# Each one is a copy of a real move puzzle from the account's own games, a
# very bad mistake on the seat it owns, started two days ago and due an
# hour ago, at the front of the deck. Copies made by an earlier run are
# replaced, so the count is the one asked for. Prints one line of JSON.
# Smokes and screenshots only: never run in dev or prod.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

import Ecto.Query

alias Oskol.Puzzles
alias Oskol.Repo

email = System.get_env("SHAPE_EMAIL") || raise "SHAPE_EMAIL is not set"
count = String.to_integer(System.get_env("DUE_COUNT") || "25")
user = Repo.get_by!(Oskol.Auth.User, email: email)
now = DateTime.utc_now()
ago = fn seconds -> DateTime.add(now, -seconds, :second) end

source =
  Repo.one!(
    from(s in Puzzles.Source,
      join: p in Puzzles.Puzzle,
      on: p.id == s.puzzle_id,
      where: s.owner_user_id == ^user.id and p.kind == "move" and not like(p.id, "due-%"),
      order_by: s.turn,
      limit: 1
    )
  )

sample = Repo.get!(Puzzles.Puzzle, source.puzzle_id)
keys = Enum.map(1..count, fn n -> "due-#{String.pad_leading(Integer.to_string(n), 3, "0")}" end)

{:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC", new_per_day: 3)
{:ok, learner} = Retain.fetch_user(user.id)

Repo.delete_all(from(i in Retain.Item, where: i.user_id == ^learner.id and like(i.key, "due-%")))
Repo.delete_all(from(s in Puzzles.Source, where: like(s.puzzle_id, "due-%")))
Repo.delete_all(from(p in Puzzles.Puzzle, where: like(p.id, "due-%")))

Repo.insert_all(
  Puzzles.Puzzle,
  Enum.map(keys, fn key ->
    %{
      id: key,
      key: key,
      kind: sample.kind,
      question: sample.question,
      answer: sample.answer,
      evaluated_by: sample.evaluated_by,
      complete: sample.complete,
      inserted_at: now,
      updated_at: now
    }
  end)
)

Repo.insert_all(
  Puzzles.Source,
  keys
  |> Enum.with_index()
  |> Enum.map(fn {key, i} ->
    %{
      puzzle_id: key,
      game_id: source.game_id,
      game_number: source.game_number,
      turn: 5000 + i,
      kind: "move",
      seat: source.seat,
      player_id: source.player_id,
      played: source.played,
      equity_lost: 0.2,
      grade: "very_bad",
      owner_user_id: user.id,
      deck_synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end)
)

{:ok, _} =
  Retain.put_items(
    user.id,
    keys
    |> Enum.with_index()
    |> Enum.map(fn {key, i} ->
      %{key: key, tags: %{"deck" => "mistakes", "kind" => "move"}, content: %{}, position: -1000 + i}
    end)
  )

from(i in Retain.Item, where: i.user_id == ^learner.id and like(i.key, "due-%"))
|> Repo.update_all(set: [level: 1, started_at: ago.(2 * 86_400), last_reviewed_at: ago.(2 * 86_400), due: ago.(3600)])

IO.puts(Jason.encode!(%{due: count, keys: length(keys)}))
