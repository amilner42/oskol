defmodule OskolWeb.GameChannel do
  @moduledoc """
  Generic game channel. The client sends `action` messages carrying the
  protocol JSON (`{name, params}`) and receives `update` messages carrying
  the scene, legal actions, outcome and events for its player.
  """
  use Phoenix.Channel
  require Logger

  alias Oskol.Game.{GameServer, GameServerState}
  alias Oskol.GameKit

  @impl true
  def join("game:" <> game_id, _params, socket) do
    # Rehydrate the room first if it only lives in the database (a deploy or
    # an idle shutdown happened since this client's page loaded).
    case Oskol.Game.lookup_game(game_id) do
      {:ok, _pid} -> join_room(game_id, socket)
      :not_found -> {:error, %{reason: "Game not found"}}
    end
  end

  defp join_room(game_id, socket) do
    try do
      # The guest cookie is the credential, and it reached the socket with
      # the websocket's own request (`OskolWeb.UserSocket`), along with the
      # account signed in on that browser. Which seat the pair opens is the
      # holder rule (`src/oskol/rooms/seat.gleam`): an owned seat answers to
      # its account and to nothing else, so a browser that logged out is
      # refused at a table it was playing a moment ago; an unowned seat
      # answers to the guest that took it. Nothing in a URL opens either. A
      # visitor who holds no seat here is refused and goes through the
      # invite link, which decides what (if anything) they may sit at.
      #
      # Attaching first also registers this channel as the seat's live
      # connection, and the join reply must describe the room after that, or
      # the joining client would see itself as disconnected.
      #
      # Who this connection belongs to: the browser tab, which outlives both
      # the channel and the socket under it -- a rejoin, a reload, a phone
      # waking its websocket back up are all the same client. The room needs
      # that to tell a reconnect from someone else taking the seat. A socket
      # that named no client is its own.
      client = socket.assigns[:client] || socket.transport_pid

      case GameServer.attach(
             game_id,
             socket.assigns[:guest_id],
             self(),
             client,
             socket.assigns[:user_id]
           ) do
        {:ok, player_id, state} ->
          Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

          socket =
            socket
            |> assign(:game_id, game_id)
            |> assign(:player_id, player_id)
            |> assign(:heard, nil)

          {:ok, %{payload: payload(state, player_id, [])}, socket}

        {:error, reason} ->
          # Never say whether the room has a seat for them, and never leak
          # room state: the invite link is the one place that answers that.
          Logger.info("Channel join refused for #{game_id}: #{inspect(reason)}")
          {:error, %{reason: "unauthorized"}}
      end
    catch
      :exit, _ -> {:error, %{reason: "Game not found"}}
    end
  end

  @impl true
  def handle_in("action", %{"action" => action}, socket) when is_map(action) do
    # A cast to a room that has gone would vanish silently: say so instead.
    case Oskol.Game.lookup_game(socket.assigns.game_id) do
      {:ok, _pid} ->
        GameServer.player_action_async(socket.assigns.game_id, socket.assigns.player_id, action)
        {:reply, :ok, socket}

      _ ->
        {:reply, {:error, %{reason: "Game not found"}}, socket}
    end
  end

  def handle_in("action", _payload, socket) do
    {:reply, {:error, %{reason: "action must be an object with name and params"}}, socket}
  end

  def handle_in("rematch", _payload, socket) do
    try do
      case GameServer.request_rematch(socket.assigns.game_id, socket.assigns.player_id) do
        {:ok, _} -> {:reply, :ok, socket}
        {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    catch
      :exit, _ -> {:reply, {:error, %{reason: "Game not found"}}, socket}
    end
  end

  # Somebody else's actions come in bursts -- a mover staging checkers, which
  # this seat sees as ghosts, or Sage stepping through a turn -- and each one
  # is a whole update. The first of a burst goes at once; anything else
  # within `coalesce_ms` of the last of them pushed waits for the end of that
  # window and goes as one update: the newest state with every event in
  # between, so nothing the client draws from is lost and a fast mover costs
  # the watcher at most one update a window. This seat's own actions, and
  # changes the room made itself (a join, a clock), never wait, and take
  # anything waiting with them.
  #
  # The channel hears each broadcast twice -- once through the subscription
  # `join_room` takes, once through the one Phoenix takes for the channel's
  # own topic -- and the second copy, straight after the first, is dropped.
  @impl true
  def handle_info({:game_state_updated, _state, _events, %{id: id}}, socket)
      when id == socket.assigns.heard do
    {:noreply, socket}
  end

  def handle_info({:game_state_updated, %GameServerState{} = state, events, meta}, socket) do
    socket = assign(socket, :heard, meta.id)
    others? = meta.by != nil and meta.by != socket.assigns.player_id
    waiting = socket.assigns[:waiting]

    socket =
      cond do
        not others? ->
          push_update(socket, state, earlier_events(waiting) ++ events)

        waiting != nil ->
          assign(socket, :waiting, {state, earlier_events(waiting) ++ events})

        true ->
          case window_left(socket) do
            0 ->
              socket
              |> push_update(state, events)
              |> assign(:burst_at, now_ms())

            ms ->
              Process.send_after(self(), :flush_update, ms)
              assign(socket, :waiting, {state, events})
          end
      end

    {:noreply, socket}
  end

  def handle_info(:flush_update, socket) do
    socket =
      case socket.assigns[:waiting] do
        {state, events} -> socket |> push_update(state, events) |> assign(:burst_at, now_ms())
        nil -> socket
      end

    {:noreply, socket}
  end

  def handle_info({:action_failed, player_id, reason}, socket) do
    if player_id == socket.assigns.player_id do
      push(socket, "error", %{message: reason})
    end

    {:noreply, socket}
  end

  def handle_info({:rematch_ready, rematch_game_id}, socket) do
    push(socket, "rematch_ready", %{game_id: rematch_game_id})
    {:noreply, socket}
  end

  # Another browser attached to this seat: that connection is the seat now,
  # so this one says so and stops rather than lingering as a second live
  # view of it. The same browser coming back never gets here -- the room
  # tells a reconnect from a takeover (`src/oskol/rooms/seat.gleam`).
  # The lobby was closed, by this browser in another tab or by the opponent
  # after claiming the seat. There is no room left to wait in, so the tab is
  # told and stops; the client shows the same "this game is gone" it shows
  # for a room that has ended any other way.
  def handle_info(:room_closed, socket) do
    push(socket, "error", %{
      message: "That game was closed. Start a new one and send a fresh link."
    })

    {:stop, :normal, socket}
  end

  def handle_info(:seat_taken_over, socket) do
    Logger.info("Seat #{socket.assigns.player_id} taken over in #{socket.assigns.game_id}")
    push(socket, "error", %{message: "This seat was opened somewhere else"})
    {:stop, :normal, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp push_update(socket, %GameServerState{} = state, events) do
    push(socket, "update", %{payload: payload(state, socket.assigns.player_id, events)})
    assign(socket, :waiting, nil)
  end

  defp earlier_events({_older, events}), do: events
  defp earlier_events(nil), do: []

  # How long until somebody else's next update may go: none of theirs pushed
  # yet, or the last of them `coalesce_ms` ago or more, is now.
  defp window_left(socket) do
    case socket.assigns[:burst_at] do
      nil -> 0
      at -> max(0, at + coalesce_ms() - now_ms())
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp coalesce_ms, do: Application.get_env(:oskol, :watch_coalesce_ms, 120)

  @doc "The message a client sees for the current room state."
  def payload(%GameServerState{instance: nil} = state, player_id, _events) do
    # A room with no game in it yet is the waiting room, and the client
    # renders it: who is seated (this seat first, by `player_id`), and the
    # one line describing what they are waiting to play.
    %{
      type: "lobby",
      game: state.slug,
      game_id: state.game_id,
      player_id: player_id,
      connections: connections_json(state),
      summary: GameServerState.summary(state),
      lobby_status: Atom.to_string(state.lobby_status)
    }
  end

  def payload(%GameServerState{} = state, player_id, events) do
    # Only a seat its guest holds ever reaches this channel, so every update
    # is that seat's own projection: hidden information stays hidden by the
    # host's per-viewer filtering.
    update = GameKit.player_update(state.instance, player_id, events)

    %{
      type: "game",
      game: state.slug,
      game_id: state.game_id,
      player_id: player_id,
      players: connections_json(state),
      rematch_ready: MapSet.to_list(state.rematch_ready),
      rematch_game_id: state.rematch_game_id,
      update: update
    }
  end

  defp connections_json(%GameServerState{} = state) do
    Enum.map(state.seat_order, fn id ->
      conn = state.connections[id]
      # `account`: whether an account owns the seat, for the badge beside
      # the name. A yes or no only: an account id never leaves the server.
      %{
        id: id,
        # An owned seat plays under its account's name; the rest under the
        # name typed at the door.
        name: GameServerState.display_name(conn),
        connected: conn.connected,
        account: conn.user_id != nil,
        # `bot`: a bot plays this seat, for the badge that says so. `thinking`:
        # it is working one out right now, which is what keeps the table from
        # looking frozen while the engine takes its seconds.
        bot: Map.get(conn, :bot, false),
        thinking: GameServerState.thinking?(state, id)
      }
    end)
  end
end
