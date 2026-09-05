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
  def join("game:" <> game_id, %{"token" => token}, socket) when is_binary(token) do
    try do
      # The seat token is the whole credential. Attaching first also
      # registers this channel as the seat's live connection, and the join
      # reply must describe the room after that, or the joining client
      # would see itself as disconnected.
      case GameServer.attach(game_id, token, self()) do
        {:ok, player_id, state} ->
          Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
          socket = socket |> assign(:game_id, game_id) |> assign(:player_id, player_id)
          {:ok, %{payload: payload(state, player_id, [])}, socket}

        {:error, reason} ->
          # Never say which of the two it was, and never leak room state.
          Logger.info("Channel join refused for #{game_id}: #{inspect(reason)}")
          {:error, %{reason: "unauthorized"}}
      end
    catch
      :exit, _ -> {:error, %{reason: "Game not found"}}
    end
  end

  # No token, no seat, and no view of the table: a visitor has to go through
  # the invite link, which decides what (if anything) they may join as.
  def join("game:" <> _game_id, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
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

  @impl true
  def handle_info({:game_state_updated, %GameServerState{} = state, events}, socket) do
    push(socket, "update", %{payload: payload(state, socket.assigns.player_id, events)})
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

  # The same token attached somewhere else: that connection is now the seat,
  # so this one stops rather than lingering as a second live view of it.
  def handle_info(:seat_taken_over, socket) do
    push(socket, "error", %{message: "This seat was opened somewhere else"})
    {:stop, :normal, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "The message a client sees for the current room state."
  def payload(%GameServerState{instance: nil} = state, _player_id, _events) do
    %{
      type: "lobby",
      game: state.slug,
      connections: connections_json(state),
      lobby_status: Atom.to_string(state.lobby_status)
    }
  end

  def payload(%GameServerState{} = state, player_id, events) do
    # Only a token-authenticated seat ever reaches this channel, so every
    # update is that seat's own projection: hidden information stays hidden
    # by the host's per-viewer filtering.
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
      %{id: id, name: conn.name, connected: conn.connected}
    end)
  end
end
