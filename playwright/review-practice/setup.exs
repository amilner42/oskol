# Everyone the practice home is drawn for, arranged once:
#
#   * six finished games graded against a stubbed engine
#     (`test-puzzle/setup.exs`, run six times), the first seat of every one
#     owned by one account -- the **shaped** account `shape.exs` then gives
#     a deck like a real player's, with a rating behind it so the cost
#     lines have something to say;
#   * a **fresh** account: signed in, nothing played;
#   * a **guest**: the second seat of the first game, unowned, so its
#     mistakes are a guest's own;
#   * the two universal sets, built against the complete stub engine.
#
#   mix run -e 'Code.eval_file("playwright/review-practice/setup.exs")'
#
# Prints one line of JSON: the shaped account's email and the guest id each
# browser carries. Screenshots only: never run in dev or prod.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

import Ecto.Query

alias Oskol.Repo

# One graded game, by the puzzle smoke's own setup. Its last line is its
# result; everything it prints is caught here so only ours reaches stdout.
graded_game = fn ->
  {:ok, io} = StringIO.open("")
  leader = Process.group_leader()
  Process.group_leader(self(), io)

  try do
    Code.eval_file("playwright/test-puzzle/setup.exs")
  after
    Process.group_leader(self(), leader)
  end

  {_, out} = StringIO.contents(io)

  out
  |> String.split("\n")
  |> Enum.map(&String.trim/1)
  |> Enum.filter(&(String.starts_with?(&1, "{") and String.ends_with?(&1, "}")))
  |> List.last()
  |> Jason.decode!()
end

games = Enum.map(1..6, fn _ -> graded_game.() end)

new_guest = fn -> :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) end

# ---------- the shaped account: the first seat of all six ----------

email = "practice-#{System.unique_integer([:positive])}@oskol.test"
user = Oskol.Auth.find_or_create_user(email)

Enum.each(games, fn game ->
  [first | _] = game["players"]
  {:ok, _} = Oskol.Auth.adopt_seats(first["guest"], new_guest.(), user.id)
end)

browser = new_guest.()
Oskol.Guests.touch(browser)
:ok = Oskol.Auth.bind_guest(browser, user.id)

# A rating like a real one: 126 decisions a game and PR 8.3 over the six,
# which is what the stub's flat totals are not. Only the seat this account
# owns is touched.
game_ids = Enum.map(games, & &1["game_id"])

Repo.query!(
  """
  UPDATE game_reviews
  SET response = jsonb_set(jsonb_set(jsonb_set(response,
        '{players,0,error}', '2.09'::jsonb),
        '{players,0,moves,decisions}', '120'::jsonb),
        '{players,0,cube,decisions}', '6'::jsonb)
  WHERE game_id = ANY($1)
  """,
  [game_ids]
)

# ---------- a fresh account ----------

fresh_email = "fresh-#{System.unique_integer([:positive])}@oskol.test"
fresh = Oskol.Auth.find_or_create_user(fresh_email)
fresh_browser = new_guest.()
Oskol.Guests.touch(fresh_browser)
:ok = Oskol.Auth.bind_guest(fresh_browser, fresh.id)

# ---------- the sets ----------

Code.require_file("test_support/complete_engine.ex")
Req.Test.set_req_test_to_shared()
analysis = Application.get_env(:oskol, :analysis, [])

Application.put_env(
  :oskol,
  :analysis,
  Keyword.merge(analysis, req_options: [plug: {Req.Test, Oskol.Reviews}])
)

Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
_ = Oskol.Decks.build(true)

# The guest: the second seat of the first game, which nobody owns.
[_, bob] = hd(games)["players"]

IO.puts(
  Jason.encode!(%{
    email: email,
    guest: browser,
    fresh: fresh_browser,
    bob: bob["guest"],
    games: game_ids
  })
)
