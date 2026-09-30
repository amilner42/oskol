# The universal sets built against the complete stub engine, and an
# account part way through the openings: what `review-decks/test.js`
# photographs.
#
#   mix run -e 'Code.eval_file("playwright/review-decks/setup.exs")'
#
# Prints one line of JSON: the guest id bound to the account.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

Code.require_file("test_support/complete_engine.ex")

Req.Test.set_req_test_to_shared()
analysis = Application.get_env(:oskol, :analysis, [])

Application.put_env(
  :oskol,
  :analysis,
  Keyword.merge(analysis, req_options: [plug: {Req.Test, Oskol.Reviews}])
)

Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)

Oskol.Decks.build(true) |> Oskol.Decks.describe() |> IO.puts()

email = "decks-#{System.unique_integer([:positive])}@oskol.test"
user = Oskol.Auth.find_or_create_user(email)
guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
Oskol.Guests.touch(guest_id)
:ok = Oskol.Auth.bind_guest(guest_id, user.id)

# The openings added; four of them already known (the top rung), three
# started and due now.
ctx = Oskol.Gleam.CtxBuilder.build()
{:ok, openings} = :oskol@practice@decks.find("openings")
{:ok, _} = :oskol@practice@decks.enroll(ctx, openings, user.id, "Europe/London")

keys = Oskol.Puzzles.deck_members("openings") |> Enum.map(& &1.puzzle_id)
{:ok, _} = Retain.master(user.id, Enum.take(keys, 4), scope: "deck:openings")
{:ok, _} = Retain.start(user.id, Enum.slice(keys, 4, 3), scope: "deck:openings")

IO.puts(Jason.encode!(%{guest_id: guest_id, email: email}))
