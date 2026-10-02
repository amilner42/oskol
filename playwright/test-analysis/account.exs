# An account for the analysis board's smoke, part 3 (SAVE): a browser
# signed into it (the guest cookie that account is bound to), and none of
# the sets an earlier run made, so the run starts from "No sets yet".
#
#   mix run -e 'Code.eval_file("playwright/test-analysis/account.exs")'
#
# Prints one line of JSON: the guest id that browser holds and the
# account's username.
#
# The sets go hard (rows and members), as the fixture's own; what their
# positions left on the account's ladder is in scopes of sets that no longer
# exist, which nothing reads.

# The last line of this script's output is its result; Ecto logs on the
# same stream.
Logger.configure(level: :warning)

alias Oskol.Auth
alias Oskol.Repo

email = "analysis-smoke@oskol.test"
username = "SavesThings"

user = Auth.find_or_create_user(email)
Auth.claim_name(user.id, username)

guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
:ok = Auth.bind_guest(guest_id, user.id)

%{rows: rows} =
  Repo.query!("SELECT id FROM decks WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])

ids = Enum.map(rows, &hd/1)

if ids != [] do
  Repo.query!("DELETE FROM deck_puzzles WHERE deck = ANY($1)", [ids])
  Repo.query!("DELETE FROM decks WHERE id = ANY($1)", [ids])
end

IO.puts(Jason.encode!(%{guest_id: guest_id, username: username}))
