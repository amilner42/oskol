defmodule OskolWeb.Api.AuthApiTest do
  @moduledoc """
  The wiring behind signing in: the routes, the envelope, the CSRF, the mail
  that goes out, the cookie that comes back, and the two things only the
  server can do — reading a mailed link without spending it, and renewing
  the session the moment a sign-in takes.

  What a sign-in decides is tested in Gleam
  (test/oskol/auth_handler_test.gleam); the rows in
  test/oskol/auth_test.exs.
  """
  # Guest and token rows are written from the request process: shared
  # sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Oskol.Auth
  alias Oskol.Auth.Limiter
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Oskol.Auth.Limiter.reset()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp new_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp csrf_checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  # A browser takes its CSRF token off the page it was served and sends it
  # back in `x-csrf-token`, exactly as the Elm client does.
  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> csrf_checked()
    |> put_req_header("x-csrf-token", token)
  end

  # Ask for a sign-in and read the link and code out of the mail that went.
  defp start_sign_in(conn, email, params \\ %{}) do
    body =
      conn
      |> post(~p"/papi/auth/start", Map.merge(%{"email" => email}, params))
      |> json_response(200)

    assert %{"ok" => true} = body

    # Swoosh's test adapter posts the mail to this process.
    assert_receive {:email, mail}
    assert mail.subject == "Sign in to Oskol"
    [_, token] = Regex.run(~r{/login/([A-Za-z0-9_-]+)}, mail.text_body)
    [_, spaced] = Regex.run(~r/code: (\d{3} \d{3})/, mail.text_body)

    %{token: token, code: String.replace(spaced, " ", ""), mail: mail}
  end

  defp with_mail_budget(budget) do
    previous = Application.fetch_env!(:oskol, :auth_mail_budget)
    Application.put_env(:oskol, :auth_mail_budget, budget)
    on_exit(fn -> Application.put_env(:oskol, :auth_mail_budget, previous) end)
  end

  defp source(conn, ip), do: put_req_header(conn, "fly-client-ip", ip)

  # ---------- POST /papi/auth/start ----------

  describe "POST /papi/auth/start" do
    test "mails a link and a code, and says nothing about the address", %{conn: conn} do
      guest = new_guest_id()

      %{token: token, code: code, mail: mail} =
        conn
        |> as_guest(guest)
        |> with_csrf()
        |> start_sign_in("Her@Example.com", %{"next" => "/backgammon/abc123"})

      assert mail.from == {"Oskol", "hello@oskol.io"}
      assert mail.to == [{"", "her@example.com"}]
      # The link is a button in the HTML half too, and the code is spelled
      # out in both.
      assert mail.html_body =~ "/login/#{token}"
      assert mail.text_body =~ "15 minutes"

      # The row is the address as it is stored, the browser that asked, and
      # where it was — with only hashes of the two secrets.
      row = Repo.one(Auth.LoginToken)
      assert row.email == "her@example.com"
      assert row.guest_id == guest
      assert row.next == "/backgammon/abc123"
      assert row.token_hash == :crypto.hash(:sha256, token)
      assert row.code_hash == :crypto.hash(:sha256, code)
    end

    test "an address that already has an account answers exactly the same", %{conn: conn} do
      Auth.find_or_create_user("her@example.com")

      assert %{"ok" => true} =
               conn
               |> with_csrf()
               |> post(~p"/papi/auth/start", %{"email" => "her@example.com"})
               |> json_response(200)
               |> Map.take(["ok"])

      assert_receive {:email, mail}
      assert mail.subject == "Sign in to Oskol"
    end

    test "something that is not an address is refused, and nothing is sent", %{conn: conn} do
      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/auth/start", %{"email" => "nobody"})
        |> json_response(422)

      assert %{"ok" => false, "error" => %{"code" => "validation_failed"}} = body
      assert_no_email_sent()
      assert Repo.aggregate(Auth.LoginToken, :count) == 0
    end

    test "a browser that asks too often is answered and not mailed", %{conn: conn} do
      conn = conn |> as_guest(new_guest_id()) |> with_csrf()

      # Ten is the allowance; the eleventh goes nowhere.
      for n <- 1..10 do
        assert %{"ok" => true} =
                 conn
                 |> post(~p"/papi/auth/start", %{"email" => "her#{n}@example.com"})
                 |> json_response(200)
      end

      assert %{"ok" => true} =
               conn
               |> post(~p"/papi/auth/start", %{"email" => "her11@example.com"})
               |> json_response(200)

      assert Repo.aggregate(Auth.LoginToken, :count) == 10
    end

    test "rotating guest cookies cannot outsend one source, while every answer stays identical",
         %{conn: conn} do
      with_mail_budget(
        guest: [limit: 10, window_s: 3_600],
        address: [limit: 30, window_s: 3_600],
        source: [limit: 2, window_s: 3_600],
        global: [limit: 200, window_s: 86_400]
      )

      bodies =
        for n <- 1..3 do
          conn
          |> as_guest(new_guest_id())
          |> with_csrf()
          |> source("203.0.113.9")
          |> post(~p"/papi/auth/start", %{"email" => "rotated#{n}@example.com"})
          |> response(200)
        end

      assert Enum.uniq(bodies) == ["{\"ok\":true}"]
      assert_receive {:email, _}
      assert_receive {:email, _}
      refute_receive {:email, _}
      assert Repo.aggregate(Auth.LoginToken, :count) == 2
    end

    test "a missing Fly header omits the source bucket instead of sharing the proxy peer", %{
      conn: conn
    } do
      with_mail_budget(
        guest: [limit: 10, window_s: 3_600],
        address: [limit: 30, window_s: 3_600],
        source: [limit: 1, window_s: 3_600],
        global: [limit: 200, window_s: 86_400]
      )

      for n <- 1..2 do
        assert %{"ok" => true} =
                 conn
                 |> as_guest(new_guest_id())
                 |> with_csrf()
                 |> post(~p"/papi/auth/start", %{"email" => "no-header#{n}@example.com"})
                 |> json_response(200)
      end

      assert_receive {:email, _}
      assert_receive {:email, _}
      assert Repo.aggregate(Auth.LoginToken, :count) == 2

      assert [] =
               :ets.tab2list(Limiter)
               |> Enum.filter(fn {key, _started, _count, _window_s} ->
                 is_binary(key) and String.starts_with?(key, "start:source:")
               end)
    end

    test "Fly source keys are stable per address, distinct, and opaque in ETS", %{conn: conn} do
      with_mail_budget(
        guest: [limit: 10, window_s: 3_600],
        address: [limit: 30, window_s: 3_600],
        source: [limit: 10, window_s: 3_600],
        global: [limit: 200, window_s: 86_400]
      )

      for {ip, n} <- [{"203.0.113.10", 1}, {"203.0.113.10", 2}, {"203.0.113.11", 3}] do
        assert %{"ok" => true} =
                 conn
                 |> as_guest(new_guest_id())
                 |> with_csrf()
                 |> source(ip)
                 |> post(~p"/papi/auth/start", %{"email" => "source#{n}@example.com"})
                 |> json_response(200)
      end

      source_entries =
        :ets.tab2list(Limiter)
        |> Enum.filter(fn {key, _started, _count, _window_s} ->
          is_binary(key) and String.starts_with?(key, "start:source:")
        end)

      assert Enum.count(source_entries) == 2
      assert Enum.sort(Enum.map(source_entries, &elem(&1, 2))) == [1, 2]

      refute Enum.any?(source_entries, fn {key, _started, _count, _window_s} ->
               key =~ "203.0.113.10" or key =~ "203.0.113.11"
             end)
    end

    test "separate sources keep their own allowance and one address keeps its ceiling", %{
      conn: conn
    } do
      with_mail_budget(
        guest: [limit: 10, window_s: 3_600],
        address: [limit: 1, window_s: 3_600],
        source: [limit: 1, window_s: 3_600],
        global: [limit: 200, window_s: 86_400]
      )

      first =
        conn
        |> as_guest(new_guest_id())
        |> with_csrf()
        |> source("203.0.113.10")
        |> post(~p"/papi/auth/start", %{"email" => "first@example.com"})
        |> response(200)

      second =
        conn
        |> as_guest(new_guest_id())
        |> with_csrf()
        |> source("203.0.113.11")
        |> post(~p"/papi/auth/start", %{"email" => "second@example.com"})
        |> response(200)

      same_address =
        conn
        |> as_guest(new_guest_id())
        |> with_csrf()
        |> source("203.0.113.12")
        |> post(~p"/papi/auth/start", %{"email" => "first@example.com"})
        |> response(200)

      assert [first, second, same_address] == List.duplicate("{\"ok\":true}", 3)
      assert_receive {:email, _}
      assert_receive {:email, _}
      refute_receive {:email, _}
      assert Repo.aggregate(Auth.LoginToken, :count) == 2
    end

    test "a write with no CSRF token is refused", %{conn: conn} do
      assert_error_sent(:forbidden, fn ->
        conn
        |> csrf_checked()
        |> post(~p"/papi/auth/start", %{"email" => "her@example.com"})
      end)
    end
  end

  # ---------- GET /login/:token ----------

  describe "GET /login/:token" do
    test "reads the token, says who it is for, and spends nothing", %{conn: conn} do
      %{token: token} =
        conn |> as_guest(new_guest_id()) |> with_csrf() |> start_sign_in("her@example.com")

      html = conn |> get(~p"/login/#{token}") |> html_response(200)

      # The page boots with what the server read, and nothing else.
      assert html =~ ~s(name="login")
      assert html =~ "confirm"
      assert html =~ "her@example.com"
      # A room is nobody's business to index; neither is a sign-in.
      assert html =~ ~s(name="robots" content="noindex")

      # Nothing was consumed and nobody was signed in: a mail scanner that
      # fetched this link has cost the player nothing.
      assert is_nil(Repo.one(Auth.LoginToken).consumed_at)
      assert Repo.aggregate(Auth.User, :count) == 0
    end

    test "a token that means nothing reads as expired", %{conn: conn} do
      html = conn |> get(~p"/login/not-a-token") |> html_response(200)

      assert html =~ "expired"
      refute html =~ "confirm"
    end

    test "a bare /login names no game and is a 404", %{conn: conn} do
      assert_error_sent(:not_found, fn -> get(conn, ~p"/login") end)
    end
  end

  # ---------- POST /papi/auth/link ----------

  describe "POST /papi/auth/link" do
    test "drops every socket the browser opened before it, so they come back as the account",
         %{conn: conn} do
      guest = new_guest_id()
      signed_in = conn |> as_guest(guest) |> with_csrf()
      %{token: token} = start_sign_in(signed_in, "her@example.com")

      # A socket's id is "guest:<id>" (UserSocket.id/1); dropping those is
      # a broadcast of "disconnect" on that topic.
      OskolWeb.Endpoint.subscribe("guest:" <> guest)
      post(signed_in, ~p"/papi/auth/link", %{"token" => token})

      # After the response, not during it: a socket dropped before the new
      # cookie arrived would reconnect on the old one.
      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_receive %Phoenix.Socket.Broadcast{topic: "guest:" <> ^guest, event: "disconnect"},
                     2_000
    end

    test "signs in the browser that posted, once, and renews its session", %{conn: conn} do
      guest = new_guest_id()
      signed_in = conn |> as_guest(guest) |> with_csrf()
      %{token: token} = start_sign_in(signed_in, "her@example.com")

      conn = post(signed_in, ~p"/papi/auth/link", %{"token" => token})

      # The session is renewed on the way out (`configure_session(renew:
      # true)`): with the cookie store the session *is* its contents, so
      # what this pins is that the sign-in writes the cookie again rather
      # than leaving the one the request arrived with in place.
      assert session_cookie(conn)

      body = json_response(conn, 200)

      assert %{"ok" => true, "saved" => 0, "next" => "/", "user" => user} = body
      assert user["email"] == "her@example.com"

      # The browser is handed a fresh guest id with the account on it, and
      # the id it arrived with is worth nothing any more: a guest id learned
      # before the sign-in (a shared laptop, dev tools) opens nothing after.
      account = Repo.one(Auth.User)
      rotated = rotated_guest(conn)
      assert rotated != guest
      assert Auth.user_id_of_guest(rotated) == account.id
      assert Auth.user_id_of_guest(guest) == nil

      # And the token is spent: opening the mail twice signs in once.
      assert %{"ok" => false} =
               signed_in
               |> post(~p"/papi/auth/link", %{"token" => token})
               |> json_response(422)
    end

    test "a token belonging to nothing is refused with one generic sentence", %{conn: conn} do
      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/auth/link", %{"token" => "made-up"})
        |> json_response(422)

      assert %{"ok" => false, "error" => %{"message" => message}} = body
      assert message =~ "expired"
      assert Repo.aggregate(Auth.User, :count) == 0
    end
  end

  # ---------- POST /papi/auth/code ----------

  describe "POST /papi/auth/code" do
    test "the code signs in the browser that asked for it", %{conn: conn} do
      guest = new_guest_id()
      laptop = conn |> as_guest(guest) |> with_csrf()
      %{code: code} = start_sign_in(laptop, "her@example.com")

      conn = post(laptop, ~p"/papi/auth/code", %{"email" => "her@example.com", "code" => code})

      assert %{"ok" => true, "saved" => 0} = json_response(conn, 200)
      assert Auth.user_id_of_guest(rotated_guest(conn)) == Repo.one(Auth.User).id
      assert Auth.user_id_of_guest(guest) == nil
    end

    test "the same code from another browser is worth nothing", %{conn: conn} do
      laptop = conn |> as_guest(new_guest_id()) |> with_csrf()
      %{code: code} = start_sign_in(laptop, "her@example.com")

      other = conn |> as_guest(new_guest_id()) |> with_csrf()

      assert %{"ok" => false, "error" => %{"message" => message}} =
               other
               |> post(~p"/papi/auth/code", %{"email" => "her@example.com", "code" => code})
               |> json_response(422)

      # The same sentence an expired link gets: nothing is given away.
      assert message =~ "expired"
      assert Repo.aggregate(Auth.User, :count) == 0
    end

    test "five wrong tries and the token is dead", %{conn: conn} do
      laptop = conn |> as_guest(new_guest_id()) |> with_csrf()
      %{code: code} = start_sign_in(laptop, "her@example.com")
      wrong = if code == "000000", do: "111111", else: "000000"

      for _ <- 1..4 do
        assert %{"error" => %{"message" => message}} =
                 laptop
                 |> post(~p"/papi/auth/code", %{"email" => "her@example.com", "code" => wrong})
                 |> json_response(422)

        assert message =~ "not right"
      end

      # The fifth try burns it, and the right code is too late.
      assert %{"ok" => false} =
               laptop
               |> post(~p"/papi/auth/code", %{"email" => "her@example.com", "code" => wrong})
               |> json_response(422)

      assert %{"ok" => false} =
               laptop
               |> post(~p"/papi/auth/code", %{"email" => "her@example.com", "code" => code})
               |> json_response(422)

      assert Repo.aggregate(Auth.User, :count) == 0
    end
  end

  # ---------- POST /papi/auth/logout ----------

  describe "POST /papi/auth/logout" do
    test "the browser is a guest again, and keeps its guest cookie", %{conn: conn} do
      guest = new_guest_id()
      signed_in = conn |> as_guest(guest) |> with_csrf()
      %{token: token} = start_sign_in(signed_in, "her@example.com")
      post(signed_in, ~p"/papi/auth/link", %{"token" => token})

      assert %{"ok" => true} =
               signed_in |> post(~p"/papi/auth/logout") |> json_response(200)

      assert Auth.user_id_of_guest(guest) == nil
      # The account itself is untouched: another browser signed into it is
      # still signed in.
      assert Repo.aggregate(Auth.User, :count) == 1
    end

    test "logging out having never logged in is fine", %{conn: conn} do
      assert %{"ok" => true} =
               conn |> with_csrf() |> post(~p"/papi/auth/logout") |> json_response(200)
    end
  end

  # ---------- GET /papi/me ----------

  describe "GET /papi/me" do
    test "names the account this browser is signed into", %{conn: conn} do
      signed_in = conn |> as_guest(new_guest_id()) |> with_csrf()
      %{token: token} = start_sign_in(signed_in, "her@example.com")
      linked = post(signed_in, ~p"/papi/auth/link", %{"token" => token})

      # The next request carries the cookie the sign-in handed back, as a
      # browser's would.
      body =
        build_conn()
        |> as_guest(rotated_guest(linked))
        |> get(~p"/papi/me")
        |> json_response(200)

      # A new account is named at its first sign-in (this browser typed no
      # name, so it is a numbered player).
      assert %{"ok" => true, "user" => %{"email" => "her@example.com", "name" => "player" <> _}} =
               body
    end

    test "a guest has no account", %{conn: conn} do
      body = conn |> get(~p"/papi/me") |> json_response(200)

      assert %{"ok" => true, "user" => nil} = body
    end
  end

  # ---------- The development endpoints ----------

  describe "the development endpoints" do
    test "the last-login endpoint does not exist outside development", %{conn: conn} do
      # :dev_routes is off under `mix test`, so the route is not declared at
      # all: there is nothing to guess at in production either.
      refute Application.get_env(:oskol, :dev_routes, false)

      # "dev" names no game, so both fall through to the ordinary 404 the
      # game routes give any unknown slug.
      assert conn |> get("/dev/last-login") |> response(404)
      assert conn |> recycle() |> get("/dev/mailbox") |> response(404)
    end
  end

  # ---------- The socket ----------

  describe "the game socket" do
    test "carries the account signed in on the browser, and answers to the browser" do
      guest = new_guest_id()
      user = Auth.find_or_create_user("her@example.com")
      :ok = Auth.bind_guest(guest, user.id)

      socket = %Phoenix.Socket{endpoint: OskolWeb.Endpoint}

      assert {:ok, connected} =
               OskolWeb.UserSocket.connect(%{"client" => "tab-1"}, socket, %{
                 session: %{"guest_id" => guest}
               })

      assert connected.assigns.guest_id == guest
      assert connected.assigns.user_id == user.id
      # What logging out broadcasts "disconnect" on: this browser's sockets,
      # not the account's (another device stays signed in and playing).
      assert OskolWeb.UserSocket.id(connected) == "guest:" <> guest
    end

    test "a browser with no account, and one with no cookie at all" do
      guest = new_guest_id()
      socket = %Phoenix.Socket{endpoint: OskolWeb.Endpoint}

      assert {:ok, as_guest} =
               OskolWeb.UserSocket.connect(%{}, socket, %{session: %{"guest_id" => guest}})

      assert as_guest.assigns.user_id == nil

      assert {:ok, nobody} = OskolWeb.UserSocket.connect(%{}, socket, %{})
      assert nobody.assigns.guest_id == nil
      assert nobody.assigns.user_id == nil
      assert OskolWeb.UserSocket.id(nobody) == nil
    end
  end

  # ---------- The Gleam boundary ----------

  describe "the Elixir twins of the Gleam records" do
    test "a Session is the tuple Gleam reads: tag, guest, account", %{conn: conn} do
      guest = new_guest_id()
      built = conn |> as_guest(guest) |> get(~p"/") |> Oskol.Gleam.CtxBuilder.session()

      assert {:session, {:some, ^guest}, :none} = built
      # And Gleam reads that tuple the way this file built it.
      refute :oskol@core@session.signed_in(built)
      assert :oskol@core@session.signed_in({:session, {:some, guest}, {:some, "a-user"}})
      assert Oskol.Gleam.CtxBuilder.anonymous_session() == {:session, :none, :none}
    end

    test "the auth caps have the tag and the field count their Gleam twin has" do
      built = Oskol.Gleam.Caps.Auth.build()
      declared = :oskol@caps@auth.stub()

      # A Gleam record is a tagged tuple: a field added on one side and not
      # the other is a silent mix-up, so it is caught here.
      assert elem(built, 0) == elem(declared, 0)
      assert tuple_size(built) == tuple_size(declared)
    end
  end

  # The guest id the sign-in rotated this browser to: the cookie it set.
  defp rotated_guest(conn) do
    %{value: id} = conn.resp_cookies["_oskol_guest"]
    id
  end

  defp session_cookie(conn) do
    conn.resp_cookies |> Map.get("_oskol_key", %{}) |> Map.get(:value)
  end
end
