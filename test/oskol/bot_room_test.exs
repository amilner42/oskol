defmodule Oskol.Game.BotRoomTest do
  @moduledoc """
  A room with a bot in one seat, played through the real bridge.

  The engine is the pure Gleam fake (`backgammon/bot.fake_answer`) behind a
  `Req.Test` stub, so the same opponent the Gleam suite plays answers here and
  nothing touches the network. The stub is shared because a think runs in a
  task of its own.
  """
  use ExUnit.Case, async: false

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.GameKit

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

  # A table with a person in one seat and Sage in the other. The game starts
  # the moment the bot sits down, exactly as a second browser would start it.
  defp table(opts \\ []) do
    game_id = unique_game_id()
    {:ok, _} = Game.start_game(game_id, "backgammon")

    {:ok, _} =
      Game.configure(game_id, %{
        format: Keyword.get(opts, :format, "single"),
        clock: "none",
        seed: Keyword.get(opts, :seed, 11)
      })

    guest = unique_guest_id()
    {:ok, human, _} = Game.join_game(game_id, "Alice", nil, guest)
    {:ok, sage, state} = Game.join_bot(game_id, "Sage")

    # Rooms outlive a test otherwise, and a bot seat left mid-think would keep
    # asking an engine the next test has stubbed for something else.
    on_exit(fn ->
      case Game.find_game(game_id) do
        {:ok, pid} -> GenServer.stop(pid, :normal)
        _ -> :ok
      end
    end)

    %{game_id: game_id, human: human, sage: sage, guest: guest, state: state}
  end

  defp eventually(fun, tries \\ 400) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  # Play the person's side, as `play_the_human` does, but stop the moment
  # `done` is true of the room -- for a test about what the table looks like
  # part-way through rather than at the end.
  defp play_until(game_id, human, done, steps \\ 0) do
    state = Game.get_server_state(game_id)

    cond do
      state.instance != nil and done.(state) ->
        :reached

      steps > 3_000 ->
        :never

      state.instance != nil and GameKit.finished?(state.instance) ->
        :over

      state.instance != nil and human in GameKit.to_act(state.instance) ->
        case Enum.reject(GameKit.legal(state.instance, human), &(&1["name"] == "resign")) do
          [] ->
            :never

          choices ->
            Game.player_action(game_id, human, Oskol.Bots.action(Enum.random(choices)))
            play_until(game_id, human, done, steps + 1)
        end

      true ->
        Process.sleep(10)
        play_until(game_id, human, done, steps + 1)
    end
  end

  # The person's side, played at random. The bot's side plays itself, so this
  # only ever acts when the room says it is the person's turn -- which is what
  # makes the test a real game between the two.
  defp play_the_human(game_id, human, steps \\ 0)

  defp play_the_human(_game_id, _human, steps) when steps > 3_000, do: {:cut_off, steps}

  defp play_the_human(game_id, human, steps) do
    state = Game.get_server_state(game_id)

    cond do
      GameKit.finished?(state.instance) ->
        {:finished, steps}

      human in GameKit.to_act(state.instance) ->
        case Enum.reject(GameKit.legal(state.instance, human), &(&1["name"] == "resign")) do
          [] ->
            {:stuck, steps}

          choices ->
            action = Oskol.Bots.action(Enum.random(choices))
            {:ok, _, _} = Game.player_action(game_id, human, action)
            play_the_human(game_id, human, steps + 1)
        end

      true ->
        # Sage's move, being thought about somewhere else.
        Process.sleep(2)
        play_the_human(game_id, human, steps)
    end
  end

  describe "a game against the bot" do
    test "plays to the finish" do
      %{game_id: game_id, human: human, sage: sage} = table()

      assert {:finished, _steps} = play_the_human(game_id, human)

      state = Game.get_server_state(game_id)
      assert {:finished, winners} = GameKit.outcome(state.instance)
      assert winners == [human] or winners == [sage]
    end

    test "plays every game of a match, saying READY for itself in between" do
      %{game_id: game_id, human: human} = table(format: "match3", seed: 7)

      assert {:finished, _steps} = play_the_human(game_id, human)
    end

    test "the bot seat is never away, so the invite has nothing to offer" do
      %{game_id: game_id, sage: sage} = table()
      state = Game.get_server_state(game_id)

      assert state.connections[sage].connected
      assert Oskol.Game.GameServerState.full?(state)

      # The person's browser is not open here, so their seat is away and the
      # invite link offers it back. Sage's is not on that list and never will
      # be: there is nobody to stand in for.
      away = Oskol.Game.GameServerState.disconnected_seats(state)
      refute Enum.any?(away, fn {id, _name, _owned} -> id == sage end)
    end

    test "the bot seat cannot be claimed, whoever asks" do
      %{game_id: game_id, sage: sage} = table()

      assert {:error, :seat_is_bot} =
               Game.claim_seat(game_id, sage, self(), unique_guest_id())

      assert {:error, :seat_is_bot} =
               Game.claim_seat(game_id, sage, self(), unique_guest_id(), Ecto.UUID.generate())
    end

    test "the bot seat is held by nobody: no guest and no account reaches it" do
      %{game_id: game_id, sage: sage, guest: guest} = table()
      state = Game.get_server_state(game_id)

      refute Oskol.Game.GameServerState.find_player_id_by_guest(state, guest) == sage
      assert Oskol.Game.GameServerState.find_player_id_by_guest(state, nil) == nil
    end

    test "one REMATCH is enough: the bot is ready as soon as the person is" do
      %{game_id: game_id, human: human} = table()
      assert {:finished, _} = play_the_human(game_id, human)

      assert {:ok, rematch_id} = Game.request_rematch(game_id, human)
      assert is_binary(rematch_id)

      on_exit(fn ->
        case Game.find_game(rematch_id) do
          {:ok, pid} -> GenServer.stop(pid, :normal)
          _ -> :ok
        end
      end)

      assert eventually(fn ->
               case Game.find_game(rematch_id) do
                 {:ok, _} -> Game.get_server_state(rematch_id).instance != nil
                 _ -> false
               end
             end)

      rematch = Game.get_server_state(rematch_id)
      assert [_, sage] = rematch.seat_order
      assert rematch.connections[sage].bot
      assert rematch.connections[sage].connected
    end
  end

  describe "an engine that never answers" do
    test "ends in an offer to resign rather than a board that never moves" do
      Req.Test.stub(Oskol.Reviews, fn conn ->
        Plug.Conn.send_resp(conn, 500, "the desktop is asleep")
      end)

      %{game_id: game_id, human: human} = table()

      # Every ask comes back empty, so after the backoff (milliseconds here)
      # the game gives up in its own words: the person is offered the game,
      # and can take it or decline and let Sage keep trying.
      offered = fn state ->
        Enum.any?(GameKit.legal(state.instance, human), &(&1["name"] == "accept_resign"))
      end

      assert play_until(game_id, human, offered) == :reached
    end
  end
end
