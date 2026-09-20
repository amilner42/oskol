defmodule Oskol.OwnershipTest do
  @moduledoc """
  A seat an account owns: who opens it, who cannot, and what happens to the
  games a browser played when it signs in.

  The rule itself lives in `src/oskol/rooms/seat.gleam` and is tested there
  in every branch; this is the room and the rows honouring it.
  """
  # Rooms write behind from their own processes, and the stamp is a write of
  # its own, so these own a shared sandbox connection and are not async.
  use ExUnit.Case, async: false

  import Oskol.GameFixtures

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Oskol.Repo, shared: true)

    on_exit(fn ->
      Oskol.Game.Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.Game.Persister
  alias Oskol.Persistence

  defp user_id, do: Ecto.UUID.generate()

  defp account(email) do
    Oskol.Auth.find_or_create_user(email).id
  end

  describe "a seat taken while signed in" do
    test "is the account's from the start, and no code opens it" do
      u1 = user_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser", u1)

      state = Game.get_server_state(game_id)
      assert state.connections[p2].user_id == u1
      assert GameServerState.owned?(state, p2)
      # The unowned seat beside it is untouched.
      refute GameServerState.owned?(state, p1)
      assert state.connections[p1].guest_id == g1

      # Nobody claims an owned seat, whatever browser they come from: not a
      # stranger with the code, not the guest that took it.
      assert {:error, :seat_owned} = Game.claim_seat(game_id, p2, self(), "a-stranger")
      assert {:error, :seat_owned} = Game.claim_seat(game_id, p2, self(), "bobs-browser")
      assert {:error, :seat_owned} = Game.claim_seat(game_id, p2, self(), "bobs-browser", u1)
    end

    test "opens from any browser signed into that account, and from no other" do
      u1 = user_id()
      %{game_id: game_id} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser", u1)

      # A second device: a guest that never played here, the same account.
      assert {:ok, ^p2, _} = Game.attach(game_id, "a-new-phone", self(), self(), u1)
      # The guest that took the seat, now logged out, is a stranger to it.
      assert {:error, :no_seat} = Game.attach(game_id, "bobs-browser", self())
      # And so is another account on that same browser.
      assert {:error, :no_seat} =
               Game.attach(game_id, "bobs-browser", self(), self(), user_id())
    end

    test "an away owned seat is never offered by the invite link" do
      u1 = user_id()
      %{game_id: game_id, p1: p1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser", u1)

      away = Game.get_server_state(game_id) |> GameServerState.disconnected_seats()

      assert {p1, "Alice", false} in away
      assert {p2, "Bob", true} in away
    end

    test "one account holds one seat per table, from however many browsers" do
      u1 = user_id()
      game_id = unique_game_id()
      {:ok, _} = Game.start_game(game_id, "backgammon")
      {:ok, _} = Game.configure(game_id, %{format: "single", clock: "none", seed: 5})
      {:ok, _p1, _} = Game.join_game(game_id, "Alice", nil, "laptop", u1)

      # The same person on a second device, which the site has never seen:
      # a different guest, the same account, and the free seat is not a
      # second one for them.
      assert {:error, :already_seated} = Game.join_game(game_id, "Alice2", nil, "phone", u1)
      # Somebody else still sits down in it.
      assert {:ok, _p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")
    end
  end

  describe "signing in" do
    test "hands this browser's seats to the account and rotates the guest" do
      u1 = account("stamp@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")
      Persister.flush()

      assert {1, [^game_id]} = Persistence.stamp_seats(g1, fresh, u1)

      [alice, bob] = Persistence.players(game_id) |> Enum.sort_by(& &1["name"])
      assert alice["id"] == p1
      assert alice["user_id"] == u1
      # The seat moved to the fresh guest with it: the old id opens nothing.
      assert alice["guest_id"] == fresh
      # The opponent's seat is untouched.
      assert bob["id"] == p2
      assert bob["user_id"] == nil
      assert bob["guest_id"] == "bobs-browser"
    end

    test "tells the live room, so memory says what the row says" do
      u1 = account("live@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      Persister.flush()

      # The cap is what a sign-in calls: the ordered write, then the rooms.
      assert {:ok, 1} = Oskol.Gleam.Caps.Auth.stamp_seats(g1, fresh, u1)

      state = Game.get_server_state(game_id)
      assert state.connections[p1].user_id == u1
      assert state.connections[p1].guest_id == fresh
      # And the room honours it at once: the old cookie is refused, the
      # account gets in from anywhere.
      assert {:error, :no_seat} = Game.attach(game_id, g1, self())
      assert {:ok, ^p1, _} = Game.attach(game_id, "somewhere-else", self(), self(), u1)
    end

    test "never takes a seat somebody else's account owns" do
      theirs = account("theirs@example.com")
      mine = account("mine@example.com")
      shared = "a-shared-laptop"

      # A shared laptop: the first person signed in here and the seat they
      # played is theirs for good. The second person gets nothing of it.
      %{game_id: game_id, p1: p1} = lobby("single")
      Persister.flush()
      {1, _} = Persistence.stamp_seats(lobby_guest(game_id, p1), shared, theirs)

      assert {0, []} = Persistence.stamp_seats(shared, unique_guest_id(), mine)
      assert Persistence.players(game_id) |> hd() |> Map.get("user_id") == theirs
    end

    test "at a table the account already sits at, the other seat stays this browser's as a guest seat" do
      mine = account("two-devices@example.com")
      shared = unique_guest_id()
      fresh = unique_guest_id()

      # One person playing both sides from two devices. One account holds
      # one seat per table, so the second seat is not stamped -- but the
      # browser's old guest id opens nothing after the sign-in, so the seat
      # must move to the fresh id with it, or that browser loses its game.
      game_id = unique_game_id()
      {:ok, _} = Game.start_game(game_id, "backgammon")
      {:ok, _} = Game.configure(game_id, %{format: "single", clock: "none", seed: 7})
      {:ok, _p1, _} = Game.join_game(game_id, "Alice", nil, "laptop", mine)
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, shared)
      Persister.flush()

      assert {0, [^game_id]} = Persistence.stamp_seats(shared, fresh, mine)

      seat = Persistence.players(game_id) |> Enum.find(&(&1["id"] == p2))
      assert seat["user_id"] == nil
      assert seat["guest_id"] == fresh
    end

    test "a seat no guest ever took can never be stamped" do
      u1 = account("tooling@example.com")
      game_id = unique_game_id()
      {:ok, _} = Game.start_game(game_id, "backgammon")
      {:ok, _} = Game.configure(game_id, %{format: "single", clock: "none", seed: 1})
      # Seeded rooms seat players held by nobody.
      {:ok, _p1, _} = Game.join_game(game_id, "P1", nil, nil)
      Persister.flush()

      # Neither nil nor "" is a browser, and a stamp keyed on one would
      # hand every pre-guest seat on the site to the first person to sign in.
      assert {0, []} = Persistence.stamp_seats("", unique_guest_id(), u1)
      assert Persistence.players(game_id) |> hd() |> Map.get("user_id") == nil
    end

    test "the seats come back owned after a rehydrate, and a rematch carries the owner" do
      u1 = account("rehydrate@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")
      Persister.flush()
      {1, _} = Persistence.stamp_seats(g1, fresh, u1)

      # The room goes away and is rebuilt from its row. The registry lets go
      # of a stopped room a moment after it stops, so wait for that before
      # asking for the room again, or the lookup finds the one that died.
      :ok = GenServer.stop(Game.find_game(game_id) |> elem(1))
      wait_until(fn -> Game.find_game(game_id) == :error end)
      assert {:ok, _} = Game.lookup_game(game_id)

      state = Game.get_server_state(game_id)
      assert state.connections[p1].user_id == u1
      assert state.connections[p1].guest_id == fresh
      assert state.connections[p2].user_id == nil
      assert {:ok, ^p1, _} = Game.attach(game_id, "any-browser", self(), self(), u1)
      assert {:error, :no_seat} = Game.attach(game_id, g1, self())
    end
  end

  describe "signing in, with the room live" do
    test "a room that rewrites its seats right after the stamp keeps the owner" do
      u1 = account("live-room@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      Persister.flush()

      # Through the cap a sign-in uses: the live room is told, the row is
      # written in order.
      assert {:ok, 1} = Oskol.Gleam.Caps.Auth.stamp_seats(g1, fresh, u1)

      # The opponent arrives: the table fills, the game starts, and the room
      # writes its whole seat list twice. Neither write may unown P1.
      {:ok, _p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")
      Persister.flush()

      seat = Persistence.players(game_id) |> Enum.find(&(&1["id"] == p1))
      assert seat["user_id"] == u1
      assert seat["guest_id"] == fresh
      assert Game.get_server_state(game_id).connections[p1].user_id == u1
    end
  end

  describe "the name a seat plays under" do
    test "an account's seat points at the account: one row renames it everywhere" do
      u1 = account("pointer@example.com")
      :ok = Oskol.Auth.claim_name(u1, "arie1")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      {:ok, p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")
      Persister.flush()

      assert {:ok, 1} = Oskol.Gleam.Caps.Auth.stamp_seats(g1, fresh, u1)

      # The live room shows the account's name; the opponent keeps theirs.
      state = Game.get_server_state(game_id)
      assert GameServerState.display_name(state.connections[p1]) == "arie1"
      assert GameServerState.display_name(state.connections[p2]) == "Bob"

      # Nothing was copied onto the seat: the row still has the name that
      # was typed at the door, and the account it points at.
      seat = Persistence.players(game_id) |> Enum.find(&(&1["id"] == p1))
      assert seat["name"] == "Alice"
      assert seat["user_id"] == u1

      # A rename is one row, and the live room shows it at once.
      :ok = Oskol.Auth.claim_name(u1, "arie2")
      :ok = Oskol.Game.GameServer.rename(game_id, u1, "arie2")

      assert Game.get_server_state(game_id).connections[p1] |> GameServerState.display_name() ==
               "arie2"

      # And every row read shows it, with nothing written.
      assert Persistence.players(game_id) |> Enum.find(&(&1["id"] == p1)) |> Map.get("name") ==
               "Alice"

      assert [named] = Persistence.display_names([Persistence.players(game_id)])
      assert Enum.find(named, &(&1["id"] == p1))["name"] == "arie2"
      assert Enum.find(named, &(&1["id"] == p2))["name"] == "Bob"
    end

    test "renaming through the handler reaches every live room, finished ones too" do
      u1 = account("live-rename@example.com")
      :ok = Oskol.Auth.claim_name(u1, "arie5")
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      Persister.flush()
      {1, _} = Persistence.stamp_seats(g1, unique_guest_id(), u1)
      1 = Oskol.Game.GameServer.stamp(game_id, g1, unique_guest_id(), u1, "arie5")

      # The real path: the handler writes the one row and tells the rooms.
      body =
        :oskol@handlers@auth.name_json(
          Oskol.Gleam.CtxBuilder.build(),
          {:session, {:some, "any-browser"}, {:some, u1}},
          "arie6"
        )

      assert {:ok, _} = body
      assert Oskol.Auth.username(u1) == "arie6"

      assert Game.get_server_state(game_id).connections[p1] |> GameServerState.display_name() ==
               "arie6"
    end

    test "a room rebuilt from its row shows the account's name" do
      u1 = account("rehydrated-name@example.com")
      :ok = Oskol.Auth.claim_name(u1, "arie3")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      Persister.flush()
      {1, _} = Persistence.stamp_seats(g1, fresh, u1)

      :ok = GenServer.stop(Game.find_game(game_id) |> elem(1))
      wait_until(fn -> Game.find_game(game_id) == :error end)
      assert {:ok, _} = Game.lookup_game(game_id)

      assert Game.get_server_state(game_id).connections[p1] |> GameServerState.display_name() ==
               "arie3"
    end

    test "a signed-in browser claiming an away seat brings its account's name" do
      u1 = account("claimer-name@example.com")
      :ok = Oskol.Auth.claim_name(u1, "arie4")
      %{game_id: game_id, p1: p1} = lobby("single")
      {:ok, _p2, _} = Game.join_game(game_id, "Bob", nil, "bobs-browser")

      # Through the cap's own shape: the caller looks the name up (a room
      # does no IO) and hands it over with the account.
      {:ok, ^p1, _} =
        Game.claim_seat(game_id, p1, self(), unique_guest_id(), u1, Oskol.Auth.username(u1))

      assert Game.get_server_state(game_id).connections[p1] |> GameServerState.display_name() ==
               "arie4"
    end
  end

  describe "a seat list written from a room's memory" do
    test "never takes an owner off a seat" do
      u1 = account("stale-write@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")
      Persister.flush()
      stale = Persistence.players(game_id)

      # The sign-in lands on disk, and the room has not heard of it yet.
      {1, _} = Persistence.stamp_seats(g1, fresh, u1)

      # It writes the seat list it has in memory: unowned, the old guest.
      :ok = Persistence.update_players(game_id, stale)

      seat = Persistence.players(game_id) |> Enum.find(&(&1["id"] == p1))
      assert seat["user_id"] == u1
      assert seat["guest_id"] == fresh
    end
  end

  describe "/papi/me/games' rows" do
    test "finds a room by the account as well as by the guest" do
      u1 = account("rows@example.com")
      fresh = unique_guest_id()
      %{game_id: game_id, g1: g1} = lobby("single")
      Persister.flush()
      {1, _} = Persistence.stamp_seats(g1, fresh, u1)

      # The browser that played it, signed out, sees nothing of it.
      refute game_id in ids(Persistence.seated_rooms(g1))
      # Its account sees it from that browser and from any other.
      assert game_id in ids(Persistence.seated_rooms(fresh))
      assert game_id in ids(Persistence.seated_rooms("a-new-phone", u1))
      assert game_id in ids(Persistence.seated_rooms(nil, u1))
      assert Persistence.seated_rooms(nil, nil) == []
    end
  end

  defp ids(rooms), do: Enum.map(rooms, & &1.id)

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  # The guest holding a seat, as the row has it.
  defp lobby_guest(game_id, player_id) do
    Persistence.players(game_id)
    |> Enum.find(%{}, &(&1["id"] == player_id))
    |> Map.get("guest_id")
  end
end
