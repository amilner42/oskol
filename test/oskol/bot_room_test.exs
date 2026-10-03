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
    test "leaves the board where it stands, and never offers a resignation" do
      Req.Test.stub(Oskol.Reviews, fn conn ->
        Plug.Conn.send_resp(conn, 500, "the desktop is asleep")
      end)

      %{game_id: game_id, human: human} = table()

      # Sage used to give up here and offer the person the game. That ended a
      # real game on an infrastructure failure -- a resignation is a result,
      # written down as a score, a rating and a review -- and one such game
      # had to be deleted from production by hand. An engine we cannot reach
      # is our problem, not a position.
      offered = fn state ->
        Enum.any?(GameKit.legal(state.instance, human), &(&1["name"] == "accept_resign"))
      end

      # `play_until` walks 3,000 steps before it gives up, and a step with
      # nothing to do is 10 ms. Starting near the end bounds this to about a
      # second, which is far past a ladder measured in milliseconds here.
      assert play_until(game_id, human, offered, 2_900) == :never

      # And the game is still there to be played, rather than over.
      state = Game.get_server_state(game_id)
      refute GameKit.finished?(state.instance)
    end
  end

  describe "pacing" do
    # The suite runs with every pace at 0; these tests set their own, small
    # enough to stay quick and large enough to measure.
    defp paced(paces) do
      before = Application.get_env(:oskol, :bot)
      Application.put_env(:oskol, :bot, Keyword.merge(before, paces))
      on_exit(fn -> Application.put_env(:oskol, :bot, before) end)
    end

    # Every step the room broadcasts, as it is received: when, the room's step
    # count after it, and the kinds of the events it carried.
    defp record(game_id) do
      parent = self()

      pid =
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
          send(parent, :listening)
          listen([])
        end)

      receive do
        :listening -> pid
      end
    end

    defp listen(seen) do
      receive do
        {:game_state_updated, state, events} when events != [] ->
          at = GameKit.now()

          kinds =
            Enum.map(GameKit.spectator_update(state.instance, events)["events"], & &1["kind"])

          listen([{at, state.action_count, kinds} | seen])

        {:seen, from} ->
          send(from, {:seen, Enum.reverse(seen)})
          listen(seen)

        _ ->
          listen(seen)
      end
    end

    defp seen(recorder) do
      send(recorder, {:seen, self()})

      receive do
        {:seen, steps} -> steps
      end
    end

    # Play the person's side at random until `enough` is true of what the
    # recorder has seen; returns the step counts the person's own actions
    # made, so everything else on the record is Sage's.
    defp play_until_seen(game_id, human, recorder, enough, mine \\ MapSet.new(), tries \\ 0) do
      state = Game.get_server_state(game_id)

      cond do
        enough.(seen(recorder), mine) ->
          mine

        tries > 3_000 or GameKit.finished?(state.instance) ->
          flunk("never saw what the test was waiting for")

        human in GameKit.to_act(state.instance) ->
          choices = Enum.reject(GameKit.legal(state.instance, human), &(&1["name"] == "resign"))
          action = Oskol.Bots.action(Enum.random(choices))
          {:ok, after_it, _} = Game.player_action(game_id, human, action)

          play_until_seen(
            game_id,
            human,
            recorder,
            enough,
            MapSet.put(mine, after_it.action_count),
            tries + 1
          )

        true ->
          Process.sleep(5)
          play_until_seen(game_id, human, recorder, enough, mine, tries + 1)
      end
    end

    # Sage's runs of consecutive steps: each a list of {at, kinds}.
    defp sages_runs(steps, mine) do
      steps
      |> Enum.chunk_by(fn {_at, count, _kinds} -> MapSet.member?(mine, count) end)
      |> Enum.reject(fn [{_at, count, _} | _] -> MapSet.member?(mine, count) end)
      |> Enum.map(fn run -> Enum.map(run, fn {at, _count, kinds} -> {at, kinds} end) end)
    end

    defp rolled_and_moved?(run) do
      length(run) >= 2 and "dice_rolled" in elem(hd(run), 1) and
        Enum.any?(run, fn {_, kinds} -> "checker_moved" in kinds end)
    end

    test "Sage's dice settle before its checkers move, and its moves come one gap apart" do
      paced(settle_ms: 200, gap_ms: 60, beat_ms: 0)
      %{game_id: game_id, human: human} = table(seed: 5)
      recorder = record(game_id)

      mine =
        play_until_seen(game_id, human, recorder, fn steps, mine ->
          Enum.any?(sages_runs(steps, mine), &rolled_and_moved?/1)
        end)

      run = Enum.find(sages_runs(seen(recorder), mine), &rolled_and_moved?/1)
      [{rolled_at, _}, {first_at, _} | _] = run

      # The dice are on the table a settle before anything else Sage does.
      # The times are when the recorder received each broadcast, and a loaded
      # runner can deliver one a few ms late: 20 ms of slack, far below what
      # unpaced play (about 0 ms) would show.
      assert first_at - rolled_at >= 200 - 20

      # And every step after that is at least a gap behind the one before.
      run
      |> Enum.drop(1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{a, _}, {b, _}] -> assert b - a >= 60 - 20 end)
    end

    test "a resignation while Sage is waiting to move drops the rest of its turn" do
      paced(settle_ms: 600, gap_ms: 600, beat_ms: 0)
      %{game_id: game_id, human: human} = table(seed: 5)
      recorder = record(game_id)

      # Up to the moment Sage's dice land on its own turn.
      mine =
        play_until_seen(game_id, human, recorder, fn steps, mine ->
          case sages_runs(steps, mine) |> List.last() do
            [{_, kinds}] -> "dice_rolled" in kinds
            _ -> false
          end
        end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state = Game.get_server_state(game_id)
          resign = Enum.find(GameKit.legal(state.instance, human), &(&1["name"] == "resign"))
          {:ok, offered, _} = Game.player_action(game_id, human, Oskol.Bots.action(resign))
          resigned_at = offered.action_count

          after_resign = fn ->
            seen(recorder)
            |> Enum.filter(fn {_at, count, _kinds} -> count > resigned_at end)
            |> Enum.flat_map(fn {_at, _count, kinds} -> kinds end)
          end

          # Sage answers the offer in a think of its own, which the room only
          # starts once the paced turn it interrupted has ended -- so by the
          # time the answer is on the record, nothing of that turn is left
          # to land. Up to 10 s on a slow runner.
          answered = &(&1 in ["resign_accepted", "resign_declined"])
          eventually(fn -> Enum.any?(after_resign.(), answered) end, 1_000)
          after_resign = after_resign.()

          # Sage answered the offer (that is a new think, about the board as
          # it stands) and played no checker it had decided on before it.
          assert Enum.any?(after_resign, &(&1 in ["resign_accepted", "resign_declined"]))

          refute "checker_moved" in Enum.take_while(
                   after_resign,
                   &(&1 not in ["resign_declined"])
                 )
        end)

      # Dropped, not refused: nothing was sent to the room to be turned down.
      refute log =~ "could not play"
      _ = mine
    end

    test "a turn's pacing stays well inside the free delay a turn gets" do
      # The numbers production plays with, not the suite's zeros.
      paces = Config.Reader.read!("config/config.exs", env: :prod)[:oskol][:bot]
      {:ok, info} = GameKit.game_info("backgammon")

      # The longest stretch the bot's clock is charged for pacing alone: a
      # beat, the dice settling, and four checkers plus the commit.
      longest = paces[:beat_ms] + paces[:settle_ms] + 5 * paces[:gap_ms]

      assert longest > 0
      assert longest <= div(info["turn_delay_ms"], 2)
    end
  end
end
