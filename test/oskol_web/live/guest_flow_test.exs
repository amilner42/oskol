defmodule OskolWeb.GuestFlowTest do
  # Guest rows are written from the LiveView process and game rows from the
  # persister's: shared sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Oskol.Game
  alias Oskol.Game.{GameSupervisor, Persister}
  alias Oskol.GameFixtures
  alias Oskol.Guests
  alias Oskol.Persistence
  alias Oskol.Repo

  @cookie "_oskol_guest"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # The real path end to end: the cookie is on the request, the plug puts it
  # in the session, the mount sees it there.
  defp as_guest(conn, guest_id), do: put_req_cookie(conn, @cookie, guest_id)

  defp new_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp create_as(conn, name) do
    {:ok, view, _} = live(conn, ~p"/backgammon")
    view |> form("form[phx-submit=new_game]", %{"player_name" => name}) |> render_submit()
    path = assert_patch(view)
    %{"game" => game_id} = URI.decode_query(URI.parse(path).query)
    game_id
  end

  defp game_row(game_id) do
    Persister.flush()
    Repo.get(Persistence.Game, game_id)
  end

  test "mounting upserts the guest row and touches last_seen_at", %{conn: conn} do
    guest_id = new_guest_id()
    {:ok, _, _} = live(as_guest(conn, guest_id), ~p"/")

    guest = Repo.get(Guests.Guest, guest_id)
    assert guest
    assert guest.name == nil

    # A later visit only moves the clock forward.
    long_ago = ~U[2020-01-01 00:00:00.000000Z]

    from(g in Guests.Guest, where: g.id == ^guest_id)
    |> Repo.update_all(set: [last_seen_at: long_ago])

    {:ok, _, _} = live(as_guest(build_conn(), guest_id), ~p"/backgammon")
    assert DateTime.compare(Repo.get(Guests.Guest, guest_id).last_seen_at, long_ago) == :gt
  end

  test "creating a game saves the name and records the guest id on the seat", %{conn: conn} do
    guest_id = new_guest_id()
    game_id = create_as(as_guest(conn, guest_id), "Alice")

    assert Repo.get(Guests.Guest, guest_id).name == "Alice"

    # The seat in the game row's players jsonb carries the guest id.
    assert [%{"name" => "Alice", "guest_id" => ^guest_id}] = game_row(game_id).players
  end

  test "joining a game saves the joiner's name and guest id too", %{conn: conn} do
    %{game_id: game_id} = GameFixtures.lobby()
    guest_id = new_guest_id()

    {:ok, view, _} = live(as_guest(conn, guest_id), ~p"/backgammon?game=#{game_id}")

    view
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert Repo.get(Guests.Guest, guest_id).name == "Bob"

    # Alice was seated by the fixture (no guest): a seat without a guest is
    # a null, and Bob's seat carries his id.
    assert [%{"name" => "Alice", "guest_id" => nil}, %{"name" => "Bob", "guest_id" => ^guest_id}] =
             game_row(game_id).players
  end

  test "the create and join forms prefill the guest's saved name", %{conn: conn} do
    guest_id = new_guest_id()
    :ok = Guests.save_name(guest_id, "Renée")

    # Create form, on the static (first) render already.
    {:ok, _, html} = live(as_guest(conn, guest_id), ~p"/backgammon")
    assert html =~ ~s(value="Renée")

    # Join form for someone else's game.
    %{game_id: game_id} = GameFixtures.lobby()
    {:ok, view, html} = live(as_guest(build_conn(), guest_id), ~p"/backgammon?game=#{game_id}")
    assert html =~ ~s(value="Renée")
    assert has_element?(view, ~s(#join-name[value="Renée"]))

    # A fresh guest sees only the placeholder.
    {:ok, _, html} = live(as_guest(build_conn(), new_guest_id()), ~p"/backgammon")
    refute html =~ ~s(value="Renée")
  end

  test "the guest id survives rehydration harmlessly", %{conn: conn} do
    guest_id = new_guest_id()
    game_id = create_as(as_guest(conn, guest_id), "Alice")
    Persister.flush()

    # Stop the room the way a deploy does, then rehydrate via lookup.
    {:ok, pid} = GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    wait_unregistered(game_id)

    assert {:ok, _pid} = Game.lookup_game(game_id)

    state = Game.get_server_state(game_id)
    assert [%{guest_id: ^guest_id, name: "Alice"}] = Map.values(state.connections)

    # And it round-trips back out through the write path unchanged.
    assert [%{"guest_id" => ^guest_id}] = game_row(game_id).players
  end

  test "the users table exists, ships empty, and guests.user_id is nullable" do
    assert Repo.all(Guests.User) == []

    guest_id = new_guest_id()
    :ok = Guests.save_name(guest_id, "Nadia")
    assert %{user_id: nil} = Repo.get(Guests.Guest, guest_id)
  end

  defp wait_unregistered(game_id, tries \\ 100) do
    case GameSupervisor.find_game(game_id) do
      :error ->
        :ok

      {:ok, _} when tries > 0 ->
        Process.sleep(10)
        wait_unregistered(game_id, tries - 1)
    end
  end
end
