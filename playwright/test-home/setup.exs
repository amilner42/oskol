# An account with a history, for the signed-in home's smoke: a browser
# signed into it, two dozen graded single games behind it so the form has
# numbers, the line has a slope and there is a page of rooms behind the
# first ten, and one match to seven -- nine games in one room -- which is
# what the recent list is a list of.
#
#   mix run -e 'Code.eval_file("playwright/test-home/setup.exs")'
#
# Prints one line of JSON: the guest id that browser holds (the cookie the
# smoke sets to become that account), the username, how many rooms and how
# many games are behind it, the match's room id, and the replay path of the
# newest single game.
#
# The games are rows, not play: what the home reads is `game_reviews` and
# `game_records` joined to an owned seat, and this writes exactly those.
# The live game the smoke wants is a real one, created and joined in the
# browser -- that part is not something a fixture should fake.

# The last line of this script's output is its result; Ecto logs on the
# same stream.
Logger.configure(level: :warning)

alias Oskol.Auth
alias Oskol.Persistence
alias Oskol.Repo
alias Oskol.Reviews

email = "home-smoke@oskol.test"
username = "HomeSmoke"

user = Auth.find_or_create_user(email)
# The name is the account's, whatever it has been called before.
Auth.claim_name(user.id, username)

guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
:ok = Auth.bind_guest(guest_id, user.id)

# Re-runnable, and bounded: every room this account already sits in goes,
# so a second run is not a home with last run's games still on it. The
# reviews and records go with them (the rooms are this fixture's own).
# `players` is a jsonb[], so a seat is found the way the home's own query
# finds one: through `oskol_players_jsonb`, which the GIN index is on.
# Postgrex encodes a jsonb parameter itself, so this hands it the term and
# not text: a string through a `::jsonb` cast becomes a JSON *string*,
# which no containment test ever matches.
%{rows: rows} =
  Repo.query!(
    "SELECT id FROM games WHERE oskol_players_jsonb(players) @> $1",
    [[%{"user_id" => user.id}]]
  )

owned = Enum.map(rows, &hd/1)

if owned != [] do
  Repo.query!("DELETE FROM game_records WHERE game_id = ANY($1)", [owned])
  Repo.query!("DELETE FROM game_reviews WHERE game_id = ANY($1)", [owned])
  Repo.query!("DELETE FROM game_actions WHERE game_id = ANY($1)", [owned])
  Repo.query!("DELETE FROM games WHERE id = ANY($1)", [owned])
end

# One seat's totals as the engine stores them: `error` is equity lost and
# `decisions` what it was lost over, which is what a rating across games is
# made of.
totals = fn error, decisions ->
  %{
    "moves" => %{
      "decisions" => decisions,
      "forced" => 0,
      "error" => error,
      "grades" => %{}
    },
    "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
    "luck" => 0.0,
    "error" => error,
    "pr" => error / decisions * 500
  }
end

# A room this account sits in, opposite a stranger, finished. `winners` is
# the row's own record of who won it, which is what the recent list reads
# to say "won" or "lost" -- so it has to be the same player the record's
# game_over line names, or the fixture would say two different things.
room = fn game_id, opponent, format, winners ->
  Repo.insert!(%Persistence.Game{
    id: game_id,
    slug: "backgammon",
    config: %{"format" => format, "clock" => "none"},
    seed: 42,
    players: [
      %{
        "id" => "p1",
        "name" => "Typed at the door",
        "guest_id" => :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
        "user_id" => user.id
      },
      %{
        "id" => "p2",
        "name" => opponent,
        "guest_id" => :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
        "user_id" => nil
      }
    ],
    status: "finished",
    winners: winners,
    inserted_at: DateTime.utc_now(),
    updated_at: DateTime.utc_now()
  })

  :ok
end

# Twenty-four games, getting better: a PR of 14.5 at the far end down to
# 3.0 at this one, so "Recent" (the last twenty) really is better than
# "Career" (all of them) and the line has somewhere to go. Ten fit on the
# home; the other fourteen are what MORE is for.
#
# What is stored is the error behind each rating, not the rating: a PR
# over several games is their error over their decisions, times 500.
decisions = 30
errors = Enum.map(23..0//-1, fn i -> (3.0 + i * 0.5) * decisions / 500 end)

newest =
  errors
  |> Enum.with_index(1)
  |> Enum.map(fn {error, n} ->
    game_id = "hs" <> String.pad_leading(Integer.to_string(n), 4, "0")
    opponent = Enum.at(["Bob", "Carol", "Dave"], rem(n, 3))
    # Every other game won, so both results show. `p1` is this account.
    winner = if rem(n, 2) == 0, do: "p1", else: "p2"
    :ok = room.(game_id, opponent, "single", [winner])

    :ok =
      Reviews.save(
        game_id,
        1,
        "done",
        1,
        %{"players" => [totals.(error, decisions), totals.(0.48, decisions)], "turns" => []},
        nil,
        nil,
        decisions
      )

    :ok =
      Reviews.save_records(
        game_id,
        [
          {1,
           [
             %{"kind" => "turn", "player" => winner},
             %{
               "kind" => "game_over",
               "number" => 1,
               "winner" => winner,
               "result" => if(rem(n, 3) == 0, do: "gammon", else: "single"),
               "points" => if(rem(n, 3) == 0, do: 2, else: 1),
               "cube" => 1,
               "scores" => %{}
             }
           ]}
        ],
        1,
        1
      )

    game_id
  end)
  |> List.last()

# One a day, oldest first: the review's own `inserted_at` is what orders
# these and what the cursor pages on, and two dozen rows written in the
# same millisecond would be a fixture that says nothing about either.
Repo.query!("""
UPDATE game_reviews
SET inserted_at = now() - (interval '1 day' * (24 - CAST(substring(game_id from 3) AS int)))
WHERE game_id LIKE 'hs0%'
""")

# A match to seven, in one room: four games lost by a point and five won
# for seven points, so the line reads "won 7-4" over nine games. This is
# the thing the recent list exists to show, and the thing a list of loose
# games said nothing about.
match_id = "hsm001"
match_games = 9
:ok = room.(match_id, "Bob", "match7", ["p1"])

match_results = [
  {1, false, 1},
  {2, false, 1},
  {3, false, 1},
  {4, false, 1},
  {5, true, 1},
  {6, true, 1},
  {7, true, 1},
  {8, true, 2},
  {9, true, 2}
]

for {{number, won, points}, index} <- Enum.with_index(match_results) do
  # It gets better as it goes, as the single games do.
  error = (9.0 - index * 0.6) * decisions / 500

  :ok =
    Reviews.save(
      match_id,
      number,
      "done",
      1,
      %{"players" => [totals.(error, decisions), totals.(0.48, decisions)], "turns" => []},
      nil,
      nil,
      decisions
    )

  winner = if won, do: "p1", else: "p2"

  :ok =
    Reviews.save_records(
      match_id,
      [
        {number,
         [
           %{"kind" => "turn", "player" => winner},
           %{
             "kind" => "game_over",
             "number" => number,
             "winner" => winner,
             "result" => "single",
             "points" => points,
             "cube" => 1,
             "scores" => %{}
           }
         ]}
      ],
      1,
      1
    )
end

# Played today, so the match is the first line of the list.
Repo.query!("UPDATE game_reviews SET inserted_at = now() WHERE game_id = $1", [match_id])

# A second account with nothing behind it at all: the home a player sees
# the day they sign up, which is a state worth looking at as often as the
# full one.
empty_user = Auth.find_or_create_user("home-empty@oskol.test")
Auth.claim_name(empty_user.id, "NewHere")
empty_guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
:ok = Auth.bind_guest(empty_guest_id, empty_user.id)

%{rows: empty_rows} =
  Repo.query!(
    "SELECT id FROM games WHERE oskol_players_jsonb(players) @> $1",
    [[%{"user_id" => empty_user.id}]]
  )

case Enum.map(empty_rows, &hd/1) do
  [] ->
    :ok

  ids ->
    Repo.query!("DELETE FROM game_records WHERE game_id = ANY($1)", [ids])
    Repo.query!("DELETE FROM game_reviews WHERE game_id = ANY($1)", [ids])
    Repo.query!("DELETE FROM game_actions WHERE game_id = ANY($1)", [ids])
    Repo.query!("DELETE FROM games WHERE id = ANY($1)", [ids])
end

IO.puts(
  Jason.encode!(%{
    guest_id: guest_id,
    empty_guest_id: empty_guest_id,
    empty_username: "NewHere",
    email: email,
    username: username,
    games: length(errors) + match_games,
    rooms: length(errors) + 1,
    match_id: match_id,
    match_games: match_games,
    newest_replay: "/backgammon/#{newest}/replay?game=1"
  })
)
