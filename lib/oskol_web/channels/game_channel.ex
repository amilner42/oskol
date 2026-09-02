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
  def join("game:" <> game_id, %{"player_id" => player_id}, socket) do
    try do
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      state = GameServer.get_state(game_id)

      # Register this channel process as the live connection for the player
      case get_in(state.connections, [player_id, :name]) do
        nil ->
          :ok

        name ->
          case GameServer.rejoin_game(game_id, name, self()) do
            {:ok, ^player_id, _} -> :ok
            {:error, :player_already_connected} -> :ok
            {:error, reason} -> Logger.warning("Channel rejoin failed: #{inspect(reason)}")
          end
      end

      socket = socket |> assign(:game_id, game_id) |> assign(:player_id, player_id)
      {:ok, %{payload: payload(state, player_id, [])}, socket}
    catch
      :exit, _ -> {:error, %{reason: "Game not found"}}
    end
  end

  def join("game:" <> _game_id, _params, _socket) do
    {:error, %{reason: "player_id required"}}
  end

  @impl true
  def handle_in("action", %{"action" => action}, socket) when is_map(action) do
    GameServer.player_action_async(socket.assigns.game_id, socket.assigns.player_id, action)
    {:reply, :ok, socket}
  end

  def handle_in("action", _payload, socket) do
    {:reply, {:error, %{reason: "action must be an object with name and params"}}, socket}
  end

  def handle_in("rematch", _payload, socket) do
    case GameServer.request_rematch(socket.assigns.game_id, socket.assigns.player_id) do
      {:ok, _} -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
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
    update =
      if Map.has_key?(state.connections, player_id) do
        GameKit.player_update(state.instance, player_id, events)
      else
        GameKit.spectator_update(state.instance, events)
      end

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
