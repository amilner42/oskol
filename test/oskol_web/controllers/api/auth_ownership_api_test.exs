defmodule OskolWeb.Api.AuthOwnershipApiTest do
  @moduledoc """
  What signing in does to the games this browser has played, over HTTP: the
  count the page shows, the fresh cookie it leaves with, and the fact that
  the id it arrived with opens nothing afterwards.

  The rule is Gleam's (`src/oskol/rooms/seat.gleam`) and the rows are tested
  in test/oskol/ownership_test.exs; this is the wiring between them.
  """
  # Rows are written from the request process and from rooms: shared
  # sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Oskol.GameFixtures

  alias Oskol.Auth
  alias Oskol.Game
  alias Oskol.Game.Persister
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Oskol.Auth.Limiter.reset()

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("x-csrf-token", token)
  end

  defp start_sign_in(conn, email) do
    assert %{"ok" => true} =
             conn |> post(~p"/papi/auth/start", %{"email" => email}) |> json_response(200)

    assert_receive {:email, mail}
    [_, token] = Regex.run(~r{/login/([A-Za-z0-9_-]+)}, mail.text_body)
    [_, spaced] = Regex.run(~r/code: (\d{3} \d{3})/, mail.text_body)
    %{token: token, code: String.replace(spaced, " ", "")}
  end

  defp guest_cookie(conn),
    do: conn.resp_cookies |> Map.get("_oskol_guest", %{}) |> Map.get(:value)

  describe "POST /papi/auth/link" do
    test "says how many games came with the account, and hands back a fresh guest", %{conn: conn} do
      guest = unique_guest_id()
      browser = conn |> as_guest(guest) |> with_csrf()

      # Two games this browser played, and one somebody else's.
      %{game_id: mine} = lobby("single", guest: guest)
      %{game_id: also_mine} = lobby("single", guest: guest)
      %{game_id: theirs} = lobby("single")
      Persister.flush()

      %{token: token} = start_sign_in(browser, "her@example.com")
      signed_in = post(browser, ~p"/papi/auth/link", %{"token" => token})

      assert %{"ok" => true, "saved" => 2} = json_response(signed_in, 200)

      # The cookie is rewritten in the very response that signs them in.
      fresh = guest_cookie(signed_in)
      assert fresh != nil
      assert fresh != guest

      account = Repo.one(Auth.User)
      # The row moved with it: the account is on the new guest, and the old
      # id is not a guest of this site any more.
      assert Auth.user_id_of_guest(fresh) == account.id
      assert Auth.user_id_of_guest(guest) == nil

      # Both of this browser's seats are the account's, and its seat moved
      # to the fresh id. The stranger's room is untouched.
      for game_id <- [mine, also_mine] do
        seat = Persistence.players(game_id) |> hd()
        assert seat["user_id"] == account.id
        assert seat["guest_id"] == fresh
      end

      assert Persistence.players(theirs) |> hd() |> Map.get("user_id") == nil

      # And the id the browser arrived with opens nothing: not the games it
      # was holding a second ago, and not the list of them.
      assert Persistence.seated_rooms(guest) == []
      assert {:error, :no_seat} = Game.attach(mine, guest, self())
    end

    test "a browser with nothing to save is signed in all the same", %{conn: conn} do
      browser = conn |> as_guest(unique_guest_id()) |> with_csrf()
      %{token: token} = start_sign_in(browser, "new@example.com")

      body =
        browser |> post(~p"/papi/auth/link", %{"token" => token}) |> json_response(200)

      assert %{"ok" => true, "saved" => 0} = body
    end
  end

  describe "POST /papi/auth/code" do
    test "the code saves this browser's games too", %{conn: conn} do
      guest = unique_guest_id()
      laptop = conn |> as_guest(guest) |> with_csrf()
      %{game_id: game_id} = lobby("single", guest: guest)
      Persister.flush()

      %{code: code} = start_sign_in(laptop, "her@example.com")

      signed_in =
        post(laptop, ~p"/papi/auth/code", %{"email" => "her@example.com", "code" => code})

      assert %{"ok" => true, "saved" => 1} = json_response(signed_in, 200)
      assert guest_cookie(signed_in) != guest

      account = Repo.one(Auth.User)
      assert Persistence.players(game_id) |> hd() |> Map.get("user_id") == account.id
    end
  end

  describe "GET /papi/me/games" do
    test "lists an owned game from a browser that never played it", %{conn: conn} do
      guest = unique_guest_id()
      browser = conn |> as_guest(guest) |> with_csrf()
      %{game_id: game_id} = lobby("single", guest: guest)
      Persister.flush()

      %{token: token} = start_sign_in(browser, "her@example.com")
      signed_in = post(browser, ~p"/papi/auth/link", %{"token" => token})
      fresh = guest_cookie(signed_in)

      assert %{"ok" => true, "games" => games} =
               build_conn()
               |> as_guest(fresh)
               |> get(~p"/papi/me/games")
               |> json_response(200)

      assert Enum.any?(games, &(&1["id"] == game_id))

      # And the browser that played it, now logged out, sees nothing of it.
      assert %{"ok" => true, "games" => []} =
               build_conn() |> as_guest(guest) |> get(~p"/papi/me/games") |> json_response(200)
    end
  end
end
