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
    ask_timeout_ms: 30_000
  ]

  @doc """
  Start a think for every bot seat whose turn it is and that is not already
  thinking. Returns the room state with those thinks recorded, for the room
  to broadcast: a seat with a think in flight is what the pulsing dot beside
  Sage's name is drawn from.

  A seat keeps its entry until the task has applied everything it decided, so
  the broadcast that follows the bot's own first action cannot start a second
  think on the same turn.
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
    game_id = state.game_id

    task =
      Task.Supervisor.async_nolink(Oskol.Game.BotSupervisor, fn ->
        run(game_id, player_id, 0)
      end)

    %GameServerState{
      state
      | bot_thinking: Map.put(state.bot_thinking, player_id, {task.ref, state.action_count})
    }
  end

  # One decision, and the actions it came to. A think that comes back empty is
  # tried again after a pause; the game is told how many have failed and
  # answers in its own words once that is too many, which is why the ladder
  # runs out here without this module deciding anything.
  defp run(game_id, player_id, attempt) do
    with {:ok, instance} <- turn_of(game_id, player_id),
         {:ok, actions} <- GameKit.think(instance, player_id, ask(), attempt) do
      play(game_id, player_id, actions)
    else
      :not_our_turn ->
        :nothing

      {:error, reason} ->
        Logger.warning(
          "Bot seat #{player_id} in game #{game_id} got nothing from the engine (attempt #{attempt + 1}): #{reason}"
        )

        case pause_after(attempt) do
          :stop -> :nothing
          pause -> retry(game_id, player_id, attempt, pause)
        end
    end
  end

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

  defp retry(game_id, player_id, attempt, pause) do
    Process.sleep(pause)
    run(game_id, player_id, attempt + 1)
  end

  # The room's own answer to whose turn it is, read afresh: a retry an entire
  # minute later must not think about a position the game has left behind.
  defp turn_of(game_id, player_id) do
    state = GameServer.get_state(game_id)

    cond do
      state.instance == nil -> :not_our_turn
      player_id in GameKit.to_act(state.instance) -> {:ok, state.instance}
      true -> :not_our_turn
    end
  catch
    # The room stopped (idle, or a deploy). Whatever rehydrates it will think
    # again from where the log left off.
    :exit, _ -> :not_our_turn
  end

  # In order, and no further than the first refusal: the rest was decided on a
  # board that no longer exists.
  defp play(_game_id, _player_id, []), do: :nothing

  defp play(game_id, player_id, actions) do
    Enum.reduce_while(actions, :played, fn action, _so_far ->
      case GameServer.player_action(game_id, player_id, action) do
        {:ok, _state, _events} ->
          {:cont, :played}

        {:error, reason} ->
          Logger.warning(
            "Bot seat #{player_id} in game #{game_id} could not play #{inspect(action)}: #{inspect(reason)}"
          )

          {:halt, :rejected}
      end
    end)
  catch
    # The room went away under us (idle, or a deploy). Nothing to report to.
    :exit, _ -> :nothing
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
