defmodule Oskol.AuthTest do
  @moduledoc """
  The rows behind signing in: the schema the accounts migration made, and
  what `Oskol.Auth` guarantees about them — hashed at rest, single use,
  expiry, tries, and a code that only redeems from the browser that asked.

  What a sign-in *decides* is tested in Gleam
  (test/oskol/auth_handler_test.gleam).
  """
  # Everything here writes rows; the sandbox owns them per test.
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Guests
  alias Oskol.Repo

  @ttl 900

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  describe "users" do
    test "an address that has never signed in gets an account; the same one after" do
      first = Auth.find_or_create_user("her@example.com")
      second = Auth.find_or_create_user("her@example.com")

      assert first.id == second.id
      assert first.email == "her@example.com"
      assert is_nil(first.name)
      # Every sign-in moves it forward.
      assert DateTime.compare(second.last_login_at, first.last_login_at) in [:gt, :eq]
    end

    test "email is case-insensitive in the column as well as in the handler" do
      user = Auth.find_or_create_user("her@example.com")

      # citext: the unique index catches a different casing rather than
      # letting a second account exist for one mailbox.
      assert Auth.find_or_create_user("HER@example.com").id == user.id
    end

    test "an account can be read back by id, and a made-up id is nobody" do
      user = Auth.find_or_create_user("her@example.com")

      assert Auth.user(user.id).email == "her@example.com"
      assert Auth.user(Ecto.UUID.generate()) == nil
      assert Auth.user("not-a-uuid") == nil
    end
  end

  describe "the browser and the account" do
    test "binding names the account on this browser's guest row; unbinding clears it" do
      guest = guest_id()
      :ok = Guests.save_name(guest, "Renée")
      user = Auth.find_or_create_user("her@example.com")

      :ok = Auth.bind_guest(guest, user.id)
      assert Auth.user_id_of_guest(guest) == user.id
      # The name the site remembers is untouched: a seat is still played
      # under a display name.
      assert Repo.get(Guests.Guest, guest).name == "Renée"

      :ok = Auth.unbind_guest(guest)
      assert Auth.user_id_of_guest(guest) == nil
    end

    test "a browser with no row and no account is simply nobody" do
      assert Auth.user_id_of_guest(guest_id()) == nil
      assert Auth.user_id_of_guest("") == nil
      assert Auth.user_id_of_guest(nil) == nil
    end
  end

  describe "login tokens" do
    test "only hashes are stored, never the token or the code" do
      {token, code} = Auth.issue("her@example.com", guest_id(), "/backgammon/abc", @ttl)

      row = Repo.one(Auth.LoginToken)

      assert row.token_hash == :crypto.hash(:sha256, token)
      assert row.code_hash == :crypto.hash(:sha256, code)
      refute row.token_hash == token
      # Nothing in the row is the secret itself.
      refute Enum.any?(Map.values(Map.from_struct(row)), &(&1 == token or &1 == code))
      assert String.length(code) == 6
      assert code =~ ~r/^\d{6}$/
      # 32 random bytes, url-safe: nothing to guess.
      assert byte_size(token) >= 40
    end

    test "verifying reads a token without spending it; consuming spends it once" do
      {token, _code} = Auth.issue("her@example.com", guest_id(), nil, @ttl)

      # However many times: a mail scanner cannot burn a link.
      assert Auth.verify(token).email == "her@example.com"
      assert Auth.verify(token).email == "her@example.com"
      assert is_nil(Repo.one(Auth.LoginToken).consumed_at)

      assert Auth.consume(token).email == "her@example.com"
      assert Auth.consume(token) == nil
      assert Auth.verify(token) == nil
    end

    test "an expired token is worth nothing" do
      {token, code} = Auth.issue("her@example.com", guest_id(), nil, @ttl)
      guest = Repo.one(Auth.LoginToken).guest_id
      expire_everything()

      assert Auth.verify(token) == nil
      assert Auth.consume(token) == nil
      assert Auth.check_code("her@example.com", code, guest, 5) == :dead
    end

    test "a token carries where the browser was, and nothing else about it" do
      {token, _} = Auth.issue("her@example.com", "g-1", "/backgammon/abc123", @ttl)

      assert Auth.verify(token).next == "/backgammon/abc123"
      assert Auth.verify(token).guest_id == "g-1"
    end

    test "several sign-ins for one address can be in flight at once" do
      {first, _} = Auth.issue("her@example.com", guest_id(), nil, @ttl)
      {second, _} = Auth.issue("her@example.com", guest_id(), nil, @ttl)

      # Asking again does not break the mail already on its way.
      assert Auth.consume(first).email == "her@example.com"
      assert Auth.consume(second).email == "her@example.com"
    end

    test "a bounded sweep retires consumed and long-expired tokens, not live ones" do
      {live, _} = Auth.issue("live@example.com", guest_id(), nil, @ttl)
      {consumed, _} = Auth.issue("consumed@example.com", guest_id(), nil, @ttl)
      {expired, _} = Auth.issue("expired@example.com", guest_id(), nil, @ttl)

      assert Auth.consume(consumed).email == "consumed@example.com"

      old = DateTime.add(DateTime.utc_now(), -86_401, :second)

      Repo.update_all(
        from(t in Auth.LoginToken, where: t.token_hash == ^:crypto.hash(:sha256, expired)),
        set: [expires_at: old]
      )

      assert Auth.sweep_dead_tokens(1) == 1
      assert Repo.aggregate(Auth.LoginToken, :count) == 2
      assert Auth.sweep_dead_tokens(1) == 1
      assert Repo.aggregate(Auth.LoginToken, :count) == 1
      assert Auth.verify(live).email == "live@example.com"
    end
  end

  describe "codes" do
    test "the right code from the browser that asked spends the token" do
      guest = guest_id()
      {_token, code} = Auth.issue("her@example.com", guest, "/x", @ttl)

      assert {:ok, row} = Auth.check_code("her@example.com", code, guest, 5)
      assert row.email == "her@example.com"
      assert row.next == "/x"

      # Single use, like the link.
      assert Auth.check_code("her@example.com", code, guest, 5) == :dead
    end

    test "the right code from another browser is worth nothing" do
      {_token, code} = Auth.issue("her@example.com", guest_id(), nil, @ttl)

      assert Auth.check_code("her@example.com", code, guest_id(), 5) == :dead
      # And it is still good for the browser that asked.
      refute Repo.one(Auth.LoginToken).consumed_at
    end

    test "a wrong code counts a try, and the token dies on the last one" do
      guest = guest_id()
      {_token, code} = Auth.issue("her@example.com", guest, nil, @ttl)
      wrong = if code == "000000", do: "111111", else: "000000"

      assert Auth.check_code("her@example.com", wrong, guest, 3) == :wrong
      assert Repo.one(Auth.LoginToken).attempts == 1
      assert Auth.check_code("her@example.com", wrong, guest, 3) == :wrong
      assert Auth.check_code("her@example.com", wrong, guest, 3) == :dead

      # Out of tries: even the right code is too late now.
      assert Auth.check_code("her@example.com", code, guest, 3) == :dead
    end

    test "a code for an address with nothing in flight is worth nothing" do
      assert Auth.check_code("nobody@example.com", "482913", guest_id(), 5) == :dead
    end
  end

  defp expire_everything do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update_all(from(t in Auth.LoginToken), set: [expires_at: past])
  end
end
