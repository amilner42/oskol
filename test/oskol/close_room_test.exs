defmodule Oskol.CloseRoomTest do
  @moduledoc """
  The two ways a room that will not end itself is ended.

  A **lobby** nobody joined is closed from outside the game -- there is no
  game in it -- through `POST /papi/games/:slug/rooms/:id/close`: the row
  takes its own status, the room stops, and nothing brings it back. An
  **unlimited session** between games is ended from inside, by the `close`
  action the engine offers there, so the log a room is rebuilt from says the
  room is over and `games.winners` names whoever was ahead, exactly as a
  match's last game does.

  The refusals are the point as much as the successes: never mid-game, never
  a match to a target, and never for anyone who does not hold a seat.

  Games are ended here by a resignation rather than by playing them out: two
  actions instead of four hundred, and what is under test is what happens at
  the pause afterwards. The bot's table is the exception -- Sage declines a
  single-point resignation off the opening position, and rightly -- so that
  one is played.
  """
  # Rows are written from the persister's process and read from the test's,
  # and the bot's engine stub is shared with the task that thinks.
  use OskolWeb.ConnCase, async: false

  alias Oskol.Game
  alias Oskol.Game.GameSupervisor
  alias Oskol.Game.Persister
  alias Oskol.GameFixtures
  alias Oskol.GameKit
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp row(game_id) do
    Persister.flush()
    Repo.get(Persistence.Game, game_id)
  end

  defp close(conn, guest_id, game_id) do
    conn |> as_guest(guest_id) |> post(~p"/papi/games/backgammon/rooms/#{game_id}/close", %{})
  end

  defp my_games(conn, guest_id) do
    conn |> as_guest(guest_id) |> get(~p"/papi/me/games") |> json_response(200)
  end

  # End the game on the board: `loser` offers to resign a single point and
  # `winner` accepts. Unlimited play then pauses between games, which is
  # where a session may be ended.
  defp resign_game(game_id, loser, winner) do
    {:ok, _, _} =
      Game.player_action(game_id, loser, %{
        "name" => "resign",
        "params" => %{"stakes" => "single"}
      })

    {:ok, _, _} = Game.player_action(game_id, winner, %{"name" => "accept_resign"})
    :ok
  end

  defp next_game(game_id, p1, p2) do
    {:ok, _, _} = Game.player_action(game_id, p1, %{"name" => "ready"})
    {:ok, _, _} = Game.player_action(game_id, p2, %{"name" => "ready"})
    :ok
  end

  # Stop a room and wait until nothing answers to its code any more.
  #
  # `Registry` forgets a dead process on its own monitor, a beat behind the
  # exit itself, so a lookup taken the instant after the DOWN can still hand
  # back the pid that has just gone -- and every call to it exits.
  defp kill_room(game_id) do
    {:ok, pid} = GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    wait_until(fn -> GameSupervisor.find_game(game_id) == :error end)
  end

  defp wait_until(check, tries \\ 400) do
    cond do
      check.() ->
        :ok

      tries == 0 ->
        flunk("the room never went away")

      true ->
        Process.sleep(5)
        wait_until(check, tries - 1)
    end
  end

  defp phase(game_id) do
    state = Game.get_server_state(game_id)
    if state.instance, do: GameKit.summary(state.instance)["phase"], else: "lobby"
  end

  # Each seat's points, from the snapshot the room writes with every step.
  defp scores(game_id) do
    state = Game.get_server_state(game_id)

    GameKit.summary(state.instance)["players"]
    |> Map.new(fn player -> {player["id"], player["counters"]["score"]} end)
  end

  describe "closing a lobby" do
    test "leaves the list, stops the room and never comes back", %{conn: conn} do
      %{game_id: game_id, g1: alice} = GameFixtures.lobby("match5")
      Persister.flush()

      assert %{"games" => [%{"id" => ^game_id, "closable" => true}]} = my_games(conn, alice)

      assert %{"ok" => true, "closed" => true} =
               conn |> close(alice, game_id) |> json_response(200)

      # Its own status: no game was played, so it is not `finished` -- there
      # is nothing to rate, nothing to review and nothing to replay.
      assert row(game_id).status == "closed"
      assert row(game_id).winners == []

      assert %{"games" => []} = my_games(conn, alice)
      assert :error = GameSupervisor.find_game(game_id)
      # Not even a lookup, which is what rehydrates every other cold room.
      assert Game.lookup_game(game_id) == :not_found
      # And the invite link says the room is gone.
      body = conn |> get(~p"/papi/games/backgammon/rooms/#{game_id}") |> json_response(200)
      assert body["state"] == "missing"
    end

    test "pressing it twice is the same answer", %{conn: conn} do
      %{game_id: game_id, g1: alice} = GameFixtures.lobby("match5")

      assert %{"ok" => true} = conn |> close(alice, game_id) |> json_response(200)
      # A second press, or a retry of a request that timed out after the
      # write landed: the same yes, and nothing woken to give it.
      assert %{"ok" => true} = conn |> close(alice, game_id) |> json_response(200)
      assert row(game_id).status == "closed"
      assert :error = GameSupervisor.find_game(game_id)
    end

    test "is refused for a browser holding no seat there, and wakes nothing", %{conn: conn} do
      %{game_id: game_id, g1: alice} = GameFixtures.lobby("match5")
      Persister.flush()

      # The room is cold. A stranger pressing this must not be the thing
      # that rebuilds somebody else's lobby from its log.
      kill_room(game_id)

      stranger = GameFixtures.unique_guest_id()
      body = conn |> close(stranger, game_id) |> json_response(422)
      assert body["error"]["message"] == "You are not at this table"

      assert :error = GameSupervisor.find_game(game_id)
      assert row(game_id).status == "waiting"
      assert %{"games" => [%{"id" => ^game_id}]} = my_games(conn, alice)
    end

    test "closes the room it names and no other", %{conn: conn} do
      %{game_id: mine, g1: alice} = GameFixtures.lobby("match5")
      %{game_id: theirs, g1: bob} = GameFixtures.lobby("match5")

      assert %{"ok" => true} = conn |> close(alice, mine) |> json_response(200)

      assert row(theirs).status == "waiting"
      assert %{"games" => [%{"id" => ^theirs}]} = my_games(conn, bob)
    end

    test "is refused once there is a game in the room", %{conn: conn} do
      %{game_id: game_id, g1: alice} = GameFixtures.started(42, "match5")
      Persister.flush()

      body = conn |> close(alice, game_id) |> json_response(422)
      assert body["error"]["message"] == "That game already started"
      assert row(game_id).status == "playing"

      # A spectator at the same table is refused for the older reason and
      # learns nothing more about the room than a stranger anywhere does.
      stranger = GameFixtures.unique_guest_id()
      refused = conn |> close(stranger, game_id) |> json_response(422)
      assert refused["error"]["message"] == "You are not at this table"
    end

    test "a room no row remembers is over, not closable", %{conn: conn} do
      guest = GameFixtures.unique_guest_id()
      body = conn |> close(guest, "000000") |> json_response(404)
      assert body["error"]["message"] =~ "That game is over"
    end

    test "a started room is never offered as closable in the list", %{conn: conn} do
      %{game_id: game_id, g1: alice} = GameFixtures.started(42, "unlimited")
      Persister.flush()

      assert %{"games" => [game]} = my_games(conn, alice)
      assert game["id"] == game_id
      assert game["closable"] == false
    end
  end

  describe "ending an unlimited session between games" do
    test "records the player ahead as the winner and stops the room offering more" do
      %{game_id: game_id, p1: p1, p2: p2, g1: g1} = GameFixtures.started(42, "unlimited")
      :ok = resign_game(game_id, p1, p2)
      assert phase(game_id) == "between_games"

      # Either player, alone: the one behind ends it here.
      {:ok, state, _events} = Game.player_action(game_id, p1, %{"name" => "close"})

      assert GameKit.outcome(state.instance) == {:finished, [p2]}
      assert row(game_id).status == "finished"
      assert row(game_id).winners == [p2]

      # The room is over: READY starts nothing, and it is out of the list a
      # returning browser is offered.
      assert {:error, _} = Game.player_action(game_id, p1, %{"name" => "ready"})
      assert Persistence.seated_rooms(g1) == []
    end

    test "survives the room being rebuilt from its log" do
      %{game_id: game_id, p1: p1, p2: p2} = GameFixtures.started(42, "unlimited")
      :ok = resign_game(game_id, p1, p2)
      {:ok, _, _} = Game.player_action(game_id, p2, %{"name" => "close"})
      Persister.flush()
      kill_room(game_id)

      # The close is a step in the log like any other, so a room rebuilt
      # from it comes back over rather than offering READY in a room whose
      # row says it is finished.
      {:ok, _} = Game.lookup_game(game_id)
      state = Game.get_server_state(game_id)
      assert GameKit.outcome(state.instance) == {:finished, [p2]}
      assert GameKit.legal_names(state.instance, p1) == []
    end

    test "is offered between games and nowhere else" do
      %{game_id: game_id, p1: p1, p2: p2} = GameFixtures.started(42, "unlimited")
      state = Game.get_server_state(game_id)

      # Mid-game: not on offer, and refused if asked for anyway.
      for id <- [p1, p2] do
        refute "close" in GameKit.legal_names(state.instance, id)
      end

      assert {:error, _} = Game.player_action(game_id, p1, %{"name" => "close"})

      :ok = resign_game(game_id, p1, p2)
      state = Game.get_server_state(game_id)

      for id <- [p1, p2] do
        assert "close" in GameKit.legal_names(state.instance, id)
      end
    end

    test "a match to a target is never closable, between games or otherwise" do
      %{game_id: game_id, p1: p1, p2: p2} = GameFixtures.started(42, "match5")
      :ok = resign_game(game_id, p1, p2)
      assert phase(game_id) == "between_games"

      state = Game.get_server_state(game_id)

      for id <- [p1, p2] do
        refute "close" in GameKit.legal_names(state.instance, id)
        assert {:error, _} = Game.player_action(game_id, id, %{"name" => "close"})
      end

      assert row(game_id).status == "playing"
    end

    test "a level score records no winner" do
      %{game_id: game_id, p1: p1, p2: p2} = GameFixtures.started(42, "unlimited")
      :ok = resign_game(game_id, p1, p2)
      :ok = next_game(game_id, p1, p2)
      :ok = resign_game(game_id, p2, p1)

      {:ok, state, _} = Game.player_action(game_id, p1, %{"name" => "close"})

      # Level is nobody's win, and `games.winners` says so with an empty
      # list rather than naming whoever happens to be first in seat order.
      assert GameKit.outcome(state.instance) == {:finished, []}
      assert row(game_id).status == "finished"
      assert row(game_id).winners == []
    end

    test "a caller who is not one of the two seats cannot end a session" do
      %{game_id: game_id, p1: p1, p2: p2} = GameFixtures.started(42, "unlimited")
      :ok = resign_game(game_id, p1, p2)

      # A stranger and a spectator never get a player id at all: the game
      # channel attaches on the holder rule and refuses everyone else, so a
      # seat is the only caller the room can be asked by. Asked anyway, with
      # an id that is not one of them, it refuses.
      assert {:error, :player_not_found} =
               Game.player_action(game_id, "nobody", %{"name" => "close"})

      assert row(game_id).status == "playing"
    end
  end

  # A session against Sage. The bot says READY for itself the moment a game
  # ends, so the pause is waiting on the person alone -- which is exactly
  # the case that would break a card only drawn while somebody is un-ready.
  describe "ending a session against the bot" do
    setup do
      Req.Test.set_req_test_to_shared()
      Req.Test.stub(Oskol.Reviews, &fake_engine/1)
      :ok
    end

    defp fake_engine(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      case :backgammon@bot.fake_answer(conn.request_path, body) do
        {:ok, answer} -> Plug.Conn.send_resp(conn, 200, answer)
        {:error, reason} -> Plug.Conn.send_resp(conn, 422, reason)
      end
    end

    test "the person may end it, the bot never does, and the score decides" do
      %{game_id: game_id, human: human, sage: sage} = bot_table()
      on_exit(fn -> stop_room(game_id) end)

      play_the_human_to_the_pause(game_id, human)

      state = Game.get_server_state(game_id)
      # Sage said READY for itself the moment the game ended, so the pause
      # is waiting on the person alone -- and it is still a pause: the card
      # they read, READY beside END SESSION, is still up.
      assert phase(game_id) == "between_games"
      assert "ready" in GameKit.legal_names(state.instance, human)
      assert "close" in GameKit.legal_names(state.instance, human)
      refute "ready" in GameKit.legal_names(state.instance, sage)

      # Ending it is on offer to the seat Sage plays too -- the engine sees
      # two seats at an unlimited table and nothing else -- but Sage never
      # takes it: its brain has nothing to do once it has said it is ready.
      Process.sleep(50)
      assert phase(game_id) == "between_games"
      assert row(game_id).status == "playing"

      scores = scores(game_id)
      leader = if scores[human] > scores[sage], do: human, else: sage
      assert scores[leader] > 0

      {:ok, state, _} = Game.player_action(game_id, human, %{"name" => "close"})

      # Whoever was ahead, which against Sage is usually Sage. A bot seat
      # holds no account, so nothing about ratings or a deck follows it;
      # what the row carries is a seat id like any other.
      assert GameKit.outcome(state.instance) == {:finished, [leader]}
      assert row(game_id).status == "finished"
      assert row(game_id).winners == [leader]
    end

    test "the bot's seat is nobody's, so no browser closes the room through it", %{conn: conn} do
      %{game_id: game_id} = bot_table()
      on_exit(fn -> stop_room(game_id) end)
      Persister.flush()

      # A browser with no guest at all must not match the bot's seat, which
      # carries neither a guest nor an account.
      body = conn |> close(GameFixtures.unique_guest_id(), game_id) |> json_response(422)
      assert body["error"]["message"] == "You are not at this table"
      assert row(game_id).status == "playing"
    end
  end

  # A table with a person in one seat and Sage in the other, playing on.
  defp bot_table do
    game_id = GameFixtures.unique_game_id()
    {:ok, _} = Game.start_game(game_id, "backgammon")
    {:ok, _} = Game.configure(game_id, %{format: "unlimited", clock: "none", seed: 11})

    guest = GameFixtures.unique_guest_id()
    {:ok, human, _} = Game.join_game(game_id, "Alice", nil, guest)
    {:ok, sage, _} = Game.join_bot(game_id, "Sage")

    %{game_id: game_id, human: human, sage: sage, guest: guest}
  end

  # Rooms outlive a test otherwise, and a bot seat left mid-think would keep
  # asking an engine the next test has stubbed for something else.
  defp stop_room(game_id) do
    case Game.find_game(game_id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      _ -> :ok
    end
  end

  # The person's side, played at random; Sage's side plays itself. Stops at
  # the pause after the first game.
  defp play_the_human_to_the_pause(game_id, human, steps \\ 0) do
    state = Game.get_server_state(game_id)

    cond do
      GameKit.summary(state.instance)["phase"] == "between_games" ->
        :ok

      steps > 3_000 ->
        flunk("never reached a pause")

      human in GameKit.to_act(state.instance) ->
        case Enum.reject(GameKit.legal(state.instance, human), &(&1["name"] == "resign")) do
          [] ->
            flunk("nothing legal for the person")

          choices ->
            {:ok, _, _} =
              Game.player_action(game_id, human, Oskol.Bots.action(Enum.random(choices)))

            play_the_human_to_the_pause(game_id, human, steps + 1)
        end

      true ->
        # Sage's move, being thought about somewhere else.
        Process.sleep(2)
        play_the_human_to_the_pause(game_id, human, steps + 1)
    end
  end
end
