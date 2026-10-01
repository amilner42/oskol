# Shape the account `setup.exs` made into a player with a real history,
# in one of the practice home's states:
#
#   SHAPE_EMAIL=... SHAPE_STATE=ladder mix run -e 'Code.eval_file("playwright/review-practice/shape.exs")'
#
# The mistakes are the real players' shape (44 very bad, 71 bad, 141
# dubious, from six graded games), spread over every rung of the ladder so
# the grid shows every colour: some patched, some on each yellow, some
# missed and back at the bottom, most never started. Both sets are added.
# Equity lost is set per band so the rating reads like a real one (PR 8.3,
# nearly all of it mistakes), and six very bad ones are patched, so "won
# back" has something to say. Practice on the four days before today makes
# the streak.
#
# SHAPE_STATE:
#
#   ladder     (default) the very bad moves have work today: some due, the
#              day's three new ones still to come, two already answered.
#              FIX ONE.
#   keep_going today's set is done everywhere: nothing due, the day's new
#              ones started and answered. The very bad moves lead with
#              KEEP GOING.
#   scheduled  every very bad move has been started and none is due: the
#              very bad moves lead with PRACTICE ANYWAY.
#   today_three
#              today's set is three away everywhere: the very bad moves have
#              nothing due, two answered today and the day's three new ones
#              still to come (5 in all); each set has three of its new ones
#              left and nothing due. FIX ONE's run of three ends on the
#              celebration (`review-celebration`).
#
# It replaces the account's mistakes and sets rather than adding to them,
# so the numbers on the shot are the ones named here. Each made-up mistake
# is a copy of a real puzzle, so every page still renders a real question.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

import Ecto.Query

alias Oskol.Puzzles
alias Oskol.Repo

email = System.get_env("SHAPE_EMAIL") || raise "SHAPE_EMAIL is not set"
state = System.get_env("SHAPE_STATE") || "ladder"

unless state in ["ladder", "keep_going", "scheduled", "today_three"],
  do: raise("SHAPE_STATE #{state} is not one of ladder, keep_going, scheduled, today_three")

user = Repo.get_by!(Oskol.Auth.User, email: email)
now = DateTime.utc_now()
day = 24 * 3600
ago = fn seconds -> DateTime.add(now, -seconds, :second) end
later = DateTime.add(now, 3 * day, :second)

# ---------- the seats this account owns, and a real puzzle to copy ----------

owned =
  Repo.query!(
    """
    SELECT g.id, p ->> 'id'
    FROM games g, LATERAL jsonb_array_elements(oskol_players_jsonb(g.players)) p
    WHERE p ->> 'user_id' = $1
    ORDER BY g.inserted_at
    """,
    [user.id]
  ).rows

[[_, _] | _] = owned
game_ids = Enum.map(owned, fn [g, _] -> g end)

sample =
  Repo.one!(
    from(p in Puzzles.Puzzle,
      join: s in Puzzles.Source,
      on: s.puzzle_id == p.id,
      where: s.game_id in ^game_ids and p.kind == "move",
      limit: 1
    )
  )

# The real mistakes of these seats go: the shot's numbers are the ones
# below and nothing else, and no sweep can sync them in behind its back.
Repo.delete_all(
  from(s in Puzzles.Source, where: s.game_id in ^game_ids and s.owner_user_id == ^user.id)
)

# {band, total, equity each, [{level, count, due?}...]}: what is started,
# rung by rung. Everything else in the band is never started.
shape = [
  {"very_bad", 44, 0.11,
   [{6, 1, false}, {5, 2, false}, {4, 3, false}, {3, 3, false}, {2, 5, true}, {1, 6, false},
    {0, 4, true}]},
  {"bad", 71, 0.06,
   [{4, 2, false}, {3, 4, false}, {2, 6, false}, {1, 9, true}, {0, 5, false}]},
  {"doubtful", 141, 0.022,
   [{3, 2, false}, {2, 5, false}, {1, 8, true}, {0, 3, false}]}
]

rows =
  shape
  |> Enum.flat_map(fn {band, total, lost, _} ->
    Enum.map(1..total, fn n -> {"shape-#{band}-#{n}", band, lost} end)
  end)
  |> Enum.with_index()

Repo.delete_all(from(p in Puzzles.Puzzle, where: like(p.id, "shape-%")))

Repo.insert_all(
  Puzzles.Puzzle,
  Enum.map(rows, fn {{key, _, _}, _} ->
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

# Each mistake in one of the six games, on the seat this account owns, a
# turn nothing real in that game has.
Repo.insert_all(
  Puzzles.Source,
  Enum.map(rows, fn {{key, band, lost}, i} ->
    [game_id, player_id] = Enum.at(owned, rem(i, length(owned)))

    %{
      puzzle_id: key,
      game_id: game_id,
      game_number: 1,
      turn: 1000 + i,
      kind: "move",
      seat: 0,
      player_id: player_id,
      played: "24/18 13/11",
      equity_lost: lost,
      grade: band,
      owner_user_id: user.id,
      deck_synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end)
)

# ---------- the mistakes, on the ladder ----------

{:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC", new_per_day: 3)
{:ok, deck} = Retain.fetch_user(user.id)
Repo.delete_all(from(i in Retain.Item, where: i.user_id == ^deck.id))

{:ok, _} =
  Retain.put_items(
    user.id,
    rows
    |> Enum.map(fn {{key, band, _}, i} ->
      %{key: key, tags: %{"deck" => "mistakes", "kind" => "move"}, content: %{}, position: i, band: band}
    end)
    |> Enum.map(&Map.drop(&1, [:band]))
  )

item = fn key -> Repo.get_by!(Retain.Item, user_id: deck.id, key: key) end

set_card = fn key, level, due_now?, started_at ->
  from(i in Retain.Item, where: i.user_id == ^deck.id and i.key == ^key)
  |> Repo.update_all(
    set: [
      level: level,
      due: if(due_now?, do: ago.(3600), else: later),
      started_at: started_at,
      last_reviewed_at: started_at
    ]
  )
end

started =
  Enum.flat_map(shape, fn {band, _, _, rungs} ->
    {list, _} =
      Enum.reduce(rungs, {[], 1}, fn {level, count, due?}, {acc, n} ->
        cards = Enum.map(n..(n + count - 1), fn k -> {"shape-#{band}-#{k}", band, level, due?} end)
        {acc ++ cards, n + count}
      end)

    list
  end)

Enum.each(started, fn {key, _, level, due?} ->
  due? = due? and state == "ladder"
  set_card.(key, level, due?, ago.(10 * day))
end)

# The days before today: an answer on each of the four, so the streak
# reads five once today has one. Answered now, then moved back a day each.
started
|> Enum.take(4)
|> Enum.with_index(1)
|> Enum.each(fn {{key, _, level, _}, back} ->
  {:ok, %{review_id: id}} = Retain.review(user.id, key, :pass)
  from(r in Retain.Review, where: r.id == ^id) |> Repo.update_all(set: [at: ago.(back * day)])
  set_card.(key, level, false, ago.(10 * day))
end)

answer_today = fn key, level ->
  {:ok, _} = Retain.review(user.id, key, :pass)
  set_card.(key, level, false, (item.(key)).started_at || now)
end

case state do
  s when s in ["ladder", "today_three"] ->
    # Two very bad ones already answered today, at the bottom yellow.
    started
    |> Enum.filter(fn {_, band, level, due?} -> band == "very_bad" and level == 1 and not due? end)
    |> Enum.take(2)
    |> Enum.each(fn {key, _, _, _} -> answer_today.(key, 2) end)

  "keep_going" ->
    # Today's set done: the three new ones started today and answered,
    # and two more besides. Nothing is due anywhere.
    ["shape-very_bad-25", "shape-very_bad-26", "shape-very_bad-27"]
    |> Enum.each(fn key ->
      set_card.(key, 0, false, ago.(60))
      answer_today.(key, 1)
    end)

    started
    |> Enum.filter(fn {_, band, level, _} -> band == "very_bad" and level == 1 end)
    |> Enum.take(2)
    |> Enum.each(fn {key, _, _, _} -> answer_today.(key, 2) end)

  "scheduled" ->
    # Every very bad move started, none due; the day's new ones spent.
    1..44
    |> Enum.each(fn n ->
      key = "shape-very_bad-#{n}"
      if (item.(key)).started_at == nil, do: set_card.(key, 1, false, ago.(10 * day))
    end)

    ["shape-bad-30", "shape-bad-31", "shape-bad-32"]
    |> Enum.each(fn key -> set_card.(key, 0, false, ago.(60)) end)
end

# ---------- the sets ----------

ctx = Oskol.Gleam.CtxBuilder.build()

set_state = fn id, learned, going, due ->
  {:ok, set} = :oskol@practice@decks.find(id)
  scope = "deck:" <> id
  {:ok, _} = :oskol@practice@decks.enroll(ctx, set, user.id, "Etc/UTC")
  {:ok, learner} = Retain.fetch_user(user.id, scope: scope)
  keys = Oskol.Puzzles.deck_members(id) |> Enum.map(& &1.puzzle_id)

  from(i in Retain.Item, where: i.user_id == ^learner.id)
  |> Repo.update_all(set: [started_at: nil, level: 0, due: now])

  Enum.with_index(keys)
  |> Enum.each(fn {key, n} ->
    {level, started} =
      cond do
        n < learned -> {5, true}
        n < learned + going -> {1 + rem(n, 3), true}
        true -> {0, false}
      end

    if started do
      from(i in Retain.Item, where: i.user_id == ^learner.id and i.key == ^key)
      |> Repo.update_all(
        set: [level: level, started_at: ago.(5 * day), due: if(n < learned + due, do: later, else: later)]
      )
    end
  end)

  # A few due now, while the day has work.
  if state == "ladder" do
    keys
    |> Enum.slice(learned, due)
    |> then(fn due_keys ->
      from(i in Retain.Item, where: i.user_id == ^learner.id and i.key in ^due_keys)
      |> Repo.update_all(set: [due: ago.(3600)])
    end)
  end

  # Done for today: the day's new ones started today.
  if state != "ladder" do
    untouched = Enum.drop(keys, learned + going)

    started_today = if state == "today_three", do: elem(set, 4) - 3, else: elem(set, 4)

    from(i in Retain.Item, where: i.user_id == ^learner.id and i.key in ^Enum.take(untouched, started_today))
    |> Repo.update_all(set: [started_at: ago.(60), level: 0, due: later])
  end
end

set_state.("openings", 4, 3, 2)
set_state.("opening_replies", 12, 20, 4)

IO.puts(Jason.encode!(%{state: state, mistakes: length(rows), started: length(started)}))
