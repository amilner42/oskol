defmodule Oskol.Game.Bot do
  @moduledoc """
  What drives a bot seat: the IO behind the game contract's `bot`.

  Gleam decides; this only fetches. A seat a bot plays is a seat with no
  guest and no account (`src/oskol/rooms/seat.gleam`), and after every change
  the room asks here whether one of them is the seat to act. If it is, a
  supervised task -- never the room, which serves live play and cannot wait
  seconds on a desktop in a house -- asks the game what to do and applies the
  answer action by action.

  Nothing here knows a backgammon word. The actions are opaque maps on their
  way back into `Oskol.GameKit.apply`, the engine is a route and a JSON body,
  and what to do about an engine that has stopped answering is the game's
  call, taken on the `attempts` this module counts.

  The one thing this module puts into a request is how deep to search
  (`config :oskol, :bot`), because that is an operator's knob -- turn it down
  and every bot on the site thinks faster -- and not a rule of any game.

  ## Pacing

  An engine that answers in a quarter of a second would otherwise have the
  bot's whole turn on the table before anybody saw its dice land. So the
  task plays what was decided at a pace a watcher can follow, here on the
  server, where every browser and spectator sees the same rhythm and the
  client stays dumb. The game says what kind of moment each action is
  (`gamekit/game.Pace`, carried on its `bot` answer); this module owns the
  milliseconds, as three knobs:

    * `settle_ms` -- after a `:settle` action (backgammon's roll: dice in
      the air on every screen), nothing more from the bot until this long
      has passed. The next decision is thought about in the meantime, so a
      think shorter than this costs the watcher nothing.
    * `gap_ms` -- between one bot action and the next (a checker moved,
      then the next).
    * `beat_ms` -- a `:beat` action (a double, a take, an answer to a
      resignation) is never applied sooner than this after the change that
      prompted it, so it is seen coming instead of found already made.

  A turn is therefore one task from the first action to the last: decide,
  play, and while it is still the bot's turn and nobody else has moved,
  decide again -- a roll and the play that follows it are two decisions,
  and the second must know when the first landed.

  Pacing never outlives the position it was for. Each action goes to the
  room process that started the think (by pid: a rehydrated room under the
  same name is somebody else's), and only if nothing has happened there
  since the bot's own last step; a resignation, a timeout or a closed room
  drops whatever was still waiting. The waits are in the task, never in the
  room, and a room that goes down wakes the task at once.
  """
  require Logger

  alias Oskol.Game.GameServer
  alias Oskol.Game.GameServerState
  alias Oskol.GameKit

  @defaults [
    move_level: "3ply",
    cube_level: "3ply",
    # The engine is a desktop in a house. A think that comes back empty is
    # tried again on this ladder, and the game gives up after the last rung.
    retry_ms: [5_000, 20_000, 60_000],
    # Then the last rung over and over, until this many asks have failed --
    # about half an hour, and the room goes idle before that anyway.
    stop_trying_after: 40,
    ask_timeout_ms: 30_000,
    # Pacing (see the moduledoc). Zero is "as fast as the engine answers".
    settle_ms: 1_600,
    gap_ms: 400,
    beat_ms: 800
  ]

  @doc """
  Start a think for every bot seat whose turn it is and that is not already
  thinking. Returns the room state with those thinks recorded, for the room
  to broadcast: a seat with a think in flight is what the pulsing dot beside
  Sage's name is drawn from.

  A seat keeps its entry until the task has played its turn through -- every
  decision, at its pace -- so the broadcast that follows the bot's own first
  action cannot start a second think on the same turn, and the dot stays lit
  from the roll to the last checker.
  """
  @spec think(GameServerState.t()) :: GameServerState.t()
  def think(%GameServerState{instance: nil} = state), do: state

  def think(%GameServerState{} = state) do
    to_act = GameKit.to_act(state.instance)

    Enum.reduce(GameServerState.bot_seats(state), state, fn player_id, state ->
      if player_id in to_act and not GameServerState.thinking?(state, player_id) and
           not stalled?(state, player_id) do
        start(state, player_id)
      else
        state
      end
    end)
  end

  @doc """
  A think that has ended, by the reference of the task that was doing it:
  `{:ok, state}` when it was one of ours, `:none` when the message belongs to
  something else (a player's socket going down).

  `outcome` is what the task made of the turn, or `:crashed` where the task
  died without saying. A think that played nothing leaves its seat alone
  until the game moves rather than being asked again the moment it exits:
  the same question at the same position would come to the same nothing, and
  asking it in a loop would be a loop through the engine.
  """
  @spec finished(GameServerState.t(), reference(), :played | :nothing | :rejected | :crashed) ::
          {:ok, GameServerState.t()} | :none
  def finished(%GameServerState{} = state, ref, outcome) do
    case Enum.find(state.bot_thinking, fn {_id, {watching, _at}} -> watching == ref end) do
      nil ->
        :none

      {player_id, {_ref, at}} ->
        state = %GameServerState{
          state
          | bot_thinking: Map.delete(state.bot_thinking, player_id)
        }

        if outcome in [:rejected, :crashed] do
          Logger.warning(
            "Bot seat #{player_id} in game #{state.game_id} ended its turn #{outcome}"
          )
        end

        if outcome == :played do
          {:ok, %GameServerState{state | bot_stalled: Map.delete(state.bot_stalled, player_id)}}
        else
          {:ok, %GameServerState{state | bot_stalled: Map.put(state.bot_stalled, player_id, at)}}
        end
    end
  end

  # ---------- The think itself ----------

  defp start(%GameServerState{} = state, player_id) do
    room = self()
    game_id = state.game_id
    at = state.action_count

    task =
      Task.Supervisor.async_nolink(Oskol.Game.BotSupervisor, fn ->
        turn(room, game_id, player_id, at)
      end)

    %GameServerState{
      state
      | bot_thinking: Map.put(state.bot_thinking, player_id, {task.ref, at})
    }
  end

  # The bot's turn, from where the room left it to where the bot hands it
  # back. `at` is the room's step count as the bot last saw it, and anything
  # else having moved the room on since is the end of this turn: the room
  # thinks afresh once the task is done. `since` and `last` are when the
  # bot's previous action landed and what kind of moment it was, which is
  # all the pacing needs to know.
  defp turn(room, game_id, player_id, at) do
    run(
      %{
        room: room,
        watch: Process.monitor(room),
        game_id: game_id,
        player_id: player_id,
        at: at,
        since: GameKit.now(),
        last: nil,
        played: false
      },
      0
    )
  end

  # One decision, and the actions it came to; then, while the turn is still
  # ours, the next. A think that comes back empty is tried again after a
  # pause; the game is told how many have failed and answers in its own words
  # once that is too many, which is why the ladder runs out here without this
  # module deciding anything.
  defp run(turn, attempt) do
    with {:ok, instance} <- turn_of(turn),
         {:ok, [_ | _] = decided} <-
           GameKit.think(instance, turn.player_id, ask(), attempt) do
      case play(turn, decided) do
        {:ok, turn} -> run(turn, 0)
        {:stop, outcome, turn} -> outcome(turn, outcome)
      end
    else
      :not_our_turn ->
        outcome(turn, :nothing)

      {:ok, []} ->
        outcome(turn, :nothing)

      {:error, reason} ->
        Logger.warning(
          "Bot seat #{turn.player_id} in game #{turn.game_id} got nothing from the engine (attempt #{attempt + 1}): #{reason}"
        )

        case pause_after(attempt) do
          :stop -> outcome(turn, :nothing)
          pause -> retry(turn, attempt, pause)
        end
    end
  end

  # A turn that played anything played, whatever stopped it after.
  defp outcome(%{played: true}, :nothing), do: :played
  defp outcome(_turn, outcome), do: outcome

  # The ladder, and then its last rung over and over.
  #
  # An engine that comes back should find Sage still waiting to play. Before
  # this the ladder simply ran out, and the game was asked what a dead engine
  # meant -- it answered with a resignation, which ended a real game on an
  # infrastructure failure and had to be undone by hand in production. The
  # game no longer answers that (`backgammon/bot` never resigns for want of
  # an engine), so something has to keep asking, and this is it.
  #
  # Bounded all the same: a think that outlived the game it was for would be
  # asking about a position nobody is looking at. The room's own idle
  # shutdown takes the task with it long before this in any case.
  defp pause_after(attempt) do
    ladder = config(:retry_ms)

    case attempt + 1 >= config(:stop_trying_after) do
      true -> :stop
      false -> Enum.at(ladder, attempt) || List.last(ladder)
    end
  end

  defp retry(turn, attempt, pause) do
    case wait_until(turn, GameKit.now() + pause) do
      :ok -> run(turn, attempt + 1)
      :gone -> outcome(turn, :nothing)
    end
  end

  # The room's own answer to whose turn it is, read afresh: a retry an entire
  # minute later must not think about a position the game has left behind,
  # and nor must the next decision of a turn somebody else has moved on.
  defp turn_of(turn) do
    state = GameServer.state_of(turn.room)

    cond do
      state.instance == nil -> :not_our_turn
      state.action_count != turn.at -> :not_our_turn
      turn.player_id in GameKit.to_act(state.instance) -> {:ok, state.instance}
      true -> :not_our_turn
    end
  catch
    # The room stopped (idle, or a deploy). Whatever rehydrates it will think
    # again from where the log left off.
    :exit, _ -> :not_our_turn
  end

  # In order, each at its pace, and no further than the first refusal: the
  # rest was decided on a board that no longer exists. A room that moved on
  # while the bot waited is not a refusal, only the end of the turn.
  defp play(turn, decided) do
    Enum.reduce_while(decided, {:ok, turn}, fn {action, pace}, {:ok, turn} ->
      with :ok <- wait_until(turn, turn.since + hold(turn.last, pace)),
           {:ok, state, _events} <-
             GameServer.bot_action(turn.room, turn.player_id, action, turn.at) do
        {:cont,
         {:ok,
          %{
            turn
            | at: state.action_count,
              since: GameKit.now(),
              last: pace,
              played: true
          }}}
      else
        :gone ->
          {:halt, {:stop, :nothing, turn}}

        {:error, :moved_on} ->
          {:halt, {:stop, :nothing, turn}}

        {:error, reason} ->
          Logger.warning(
            "Bot seat #{turn.player_id} in game #{turn.game_id} could not play #{inspect(action)}: #{inspect(reason)}"
          )

          {:halt, {:stop, :rejected, turn}}
      end
    end)
  catch
    # The room went away under us (idle, or a deploy). Nothing to report to.
    :exit, _ -> {:stop, :nothing, turn}
  end

  # How long after the bot's previous action (or, for its first, after the
  # change that started the think) this one may land.
  defp hold(last, pace) do
    after_last =
      case last do
        nil -> 0
        :settle -> config(:settle_ms)
        _ -> config(:gap_ms)
      end

    own = if pace == :beat, do: config(:beat_ms), else: 0
    max(after_last, own)
  end

  # Wait in the task until `deadline` (monotonic ms), or until the room goes
  # down, whichever is first: a stopped room is no reason to sleep on.
  defp wait_until(turn, deadline) do
    case deadline - GameKit.now() do
      ms when ms > 0 ->
        watch = turn.watch

        receive do
          {:DOWN, ^watch, :process, _pid, _reason} -> :gone
        after
          ms -> :ok
        end

      _ ->
        :ok
    end
  end

  # ---------- The engine ----------

  # The analysis engine as the game sees it: a route and a JSON body in, the
  # answer's body out. The search depth is merged in on the way past because
  # it is configuration rather than a question the game is asking.
  defp ask do
    fn route, body ->
      Oskol.Reviews.ask(route, at_configured_level(body), config(:ask_timeout_ms))
    end
  end

  defp at_configured_level(body) do
    body
    |> Jason.decode!()
    |> Map.put("move_level", config(:move_level))
    |> Map.put("cube_level", config(:cube_level))
    |> Jason.encode!()
  end

  defp config(key) do
    Application.get_env(:oskol, :bot, [])
    |> Keyword.get(key, @defaults[key])
  end

  defp stalled?(%GameServerState{} = state, player_id) do
    Map.get(state.bot_stalled, player_id) == state.action_count
  end
end
