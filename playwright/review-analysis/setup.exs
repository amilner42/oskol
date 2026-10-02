# Everything the Analysis milestone's screenshots are taken of, arranged
# once, on a database of its own:
#
#   * the seeded match at 821900, really graded, every checker play given
#     every legal play (`test-backgammon-replay/share_setup.exs`): the
#     replay's OPEN IN ANALYSIS and SHARE, and the shared page's way back;
#   * the universal sets, built against the complete stub engine, so
#     /puzzles shows all five before "Your sets";
#   * an account (signed in through the guest cookie it is bound to) with
#     none of the sets an earlier run made: `test.js` makes "Openings I
#     like" through the page's own API, so the set is a set like any other.
#
#   mix run -e 'Code.eval_file("playwright/review-analysis/setup.exs")'
#
# Prints one line of JSON: the account's guest cookie, its email and the
# room. Screenshots and a review server only: never run in dev or prod.

Logger.configure(level: :warning)
Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)

alias Oskol.Repo

# The replay smoke's own arrangement of the seeded match. Its last line is
# its result; everything it prints is caught here so only ours reaches
# stdout.
quietly = fn path ->
  {:ok, io} = StringIO.open("")
  leader = Process.group_leader()
  Process.group_leader(self(), io)

  try do
    Code.eval_file(path)
  after
    Process.group_leader(self(), leader)
  end
end

quietly.("playwright/test-backgammon-replay/share_setup.exs")

# ---------- the five universal sets ----------

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

# ---------- the account ----------

email = "analysis-review@oskol.test"
username = "KeepsPositions"

user = Oskol.Auth.find_or_create_user(email)
Oskol.Auth.claim_name(user.id, username)

guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
Oskol.Guests.touch(guest_id)
:ok = Oskol.Auth.bind_guest(guest_id, user.id)

%{rows: rows} =
  Repo.query!("SELECT id FROM decks WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])

ids = Enum.map(rows, &hd/1)

# A run starts from no sets (test.js makes the one it shoots); serve.sh
# keeps whatever is there (KEEP_SETS=1), so a walk after a run finds it.
if ids != [] and System.get_env("KEEP_SETS") != "1" do
  Repo.query!("DELETE FROM deck_puzzles WHERE deck = ANY($1)", [ids])
  Repo.query!("DELETE FROM decks WHERE id = ANY($1)", [ids])
end

IO.puts(Jason.encode!(%{guest_id: guest_id, email: email, username: username, room: "821900"}))
