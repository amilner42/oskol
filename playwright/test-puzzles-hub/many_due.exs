# Give an account more very bad moves due today than one page of a session
# holds, so a run through them has to ask its queue again to get past the
# twentieth:
#
#   SHAPE_EMAIL=... DUE_COUNT=25 mix run -e 'Code.eval_file("playwright/test-puzzles-hub/many_due.exs")'
#
# Each one is a copy of a real move puzzle from the account's own games, a
# very bad mistake on the seat it owns, started two days ago and due an
# hour ago, at the front of the deck. Copies made by an earlier run are
# replaced, so the count is the one asked for.
#
# DUE_MODE=start_all instead leaves nothing new anywhere -- every mistake
# the account has never been shown is started, due in three days -- and
# adds ten more very bad moves in rotation, due in three days, so the end
# of a run offers PRACTICE ANYWAY and the rotation holds more than the
# ones just answered. (Not `MODE`: the dev config sets that one.)
#
# Prints one line of JSON. Smokes and screenshots only: never run in dev or
# prod.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

import Ecto.Query

alias Oskol.Puzzles
alias Oskol.Repo

email = System.get_env("SHAPE_EMAIL") || raise "SHAPE_EMAIL is not set"
start_all = System.get_env("DUE_MODE") == "start_all"
count = if start_all, do: 10, else: String.to_integer(System.get_env("DUE_COUNT") || "25")
prefix = if start_all, do: "SPAR", else: "DUEQ"
user = Repo.get_by!(Oskol.Auth.User, email: email)
now = DateTime.utc_now()
ago = fn seconds -> DateTime.add(now, -seconds, :second) end
due_at = if start_all, do: DateTime.add(now, 3 * 86_400, :second), else: ago.(3600)

{:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC", new_per_day: 3)
{:ok, learner} = Retain.fetch_user(user.id)

started =
  if start_all do
    {n, _} =
      from(i in Retain.Item, where: i.user_id == ^learner.id and is_nil(i.started_at))
      |> Repo.update_all(set: [level: 1, started_at: ago.(86_400), due: due_at])

    n
  else
    0
  end

source =
  Repo.one!(
    from(s in Puzzles.Source,
      join: p in Puzzles.Puzzle,
      on: p.id == s.puzzle_id,
      where:
        s.owner_user_id == ^user.id and p.kind == "move" and not like(p.id, "DUEQ%") and
          not like(p.id, "SPAR%"),
      order_by: s.turn,
      limit: 1
    )
  )

sample = Repo.get!(Puzzles.Puzzle, source.puzzle_id)
pattern = prefix <> "%"

keys =
  Enum.map(1..count, fn n -> "#{prefix}#{String.pad_leading(Integer.to_string(n), 4, "0")}" end)

Repo.delete_all(from(i in Retain.Item, where: i.user_id == ^learner.id and like(i.key, ^pattern)))
Repo.delete_all(from(s in Puzzles.Source, where: like(s.puzzle_id, ^pattern)))
Repo.delete_all(from(p in Puzzles.Puzzle, where: like(p.id, ^pattern)))

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
      turn: if(start_all, do: 6000, else: 5000) + i,
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

from(i in Retain.Item, where: i.user_id == ^learner.id and like(i.key, ^pattern))
|> Repo.update_all(
  set: [level: 1, started_at: ago.(2 * 86_400), last_reviewed_at: ago.(2 * 86_400), due: due_at]
)

IO.puts(Jason.encode!(%{prefix: prefix, keys: length(keys), started: started}))
