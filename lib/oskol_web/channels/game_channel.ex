defmodule OskolWeb.GameChannel do
  use Phoenix.Channel
  require Logger

  alias Oskol.Game.{GameServer, GleamEngine}

  @impl true
  def join("game:" <> game_id, %{"player_id" => player_id}, socket) do
    try do
      # Subscribe to game updates via PubSub
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      # Get current game state - returns GameServerState directly
      game_server_state = GameServer.get_state(game_id)

      # Get player name from connections to register this channel process
      player_name = get_in(game_server_state.connections, [player_id, :name])

      # Register this channel process as the active connection for this player
      if player_name do
        case GameServer.rejoin_game(game_id, player_name, self()) do
          {:ok, ^player_id, _updated_state} ->
            # Successfully registered connection
            :ok

          {:error, :player_already_connected} ->
            # This is fine - player is already connected (maybe via LiveView)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to register channel connection: #{inspect(reason)}")
        end
      end

      socket =
        socket
        |> assign(:game_id, game_id)
        |> assign(:player_id, player_id)

      # Return the game state as JSON
      # Handle both lobby (game_state == nil) and active game states
      game_state_json =
        if game_server_state.game_state == nil do
          # Game hasn't started yet - return lobby state
          %{
            type: "lobby",
            connections: game_server_state.connections,
            lobby_status: Atom.to_string(game_server_state.lobby_status)
          }
        else
          # Game is active - get player-specific view from Gleam
          GleamEngine.get_player_view(game_server_state.game_state, player_id)
        end

      {:ok, %{game_state: game_state_json}, socket}
    catch
      :exit, _ ->
        {:error, %{reason: "Game not found"}}
    end
  end

  @impl true
  def join("game:" <> _game_id, _params, _socket) do
    {:error, %{reason: "player_id required"}}
  end

  # Handle player actions
  @impl true
  def handle_in("lock_in_hand", %{"cards" => cards}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    # Convert JSON card maps to Card structs
    card_structs = Enum.map(cards, &json_to_card/1)

    GameServer.player_action_async(game_id, player_id, {:lock_in_hand, card_structs})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("discard_cards", %{"cards" => cards}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    # Convert JSON card maps to Card structs
    card_structs = Enum.map(cards, &json_to_card/1)

    GameServer.player_action_async(game_id, player_id, {:discard_cards, card_structs})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("make_shop_pick", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, {:make_shop_pick, card_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("confirm_deck_builder_pick", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, {:confirm_deck_builder_pick, card_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_deck_builder_selection", %{"card_ids" => card_ids}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(
      game_id,
      player_id,
      {:complete_deck_builder_selection, card_ids}
    )

    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("skip_deck_builder_selection", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, :skip_deck_builder_selection)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("confirm_plus_bomb_pick", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, {:confirm_plus_bomb_pick, card_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_plus_bomb_selection", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, {:complete_plus_bomb_selection, card_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("destroy_shop_card", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, {:destroy_shop_card, card_id})
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_destroy_phase", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.player_action_async(game_id, player_id, :complete_destroy_phase)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("request_rematch", _params, socket) do
    game_id = socket.assigns.game_id
    _player_id = socket.assigns.player_id

    # Get current game state
    game_server_state = GameServer.get_state(game_id)

    # If game is over, trigger rematch immediately
    if game_server_state.game_state != nil do
      game_info = GleamEngine.get_game_info(game_server_state.game_state)

      if game_info.game_status == :game_over do
        # Generate rematch game ID
        rematch_game_id = generate_rematch_id(game_id)

        # Get player names and game settings from current game
        player_names =
          GleamEngine.get_player_names(game_server_state.game_state)
          |> Map.values()
          |> Enum.to_list()

        config = GleamEngine.get_game_config(game_server_state.game_state)
        initial_lives = config.initial_lives
        # Shop rounds not yet in Gleam - use default of 2 for standard format
        shop_rounds = 2

        # Determine format based on settings
        format = config_to_format(initial_lives, shop_rounds)

        # Start the new game server
        case Oskol.Game.GameSupervisor.start_game(rematch_game_id) do
          {:ok, _pid} ->
            # Join both players to the new game (PIDs will be set when they actually connect)
            [player1_name, player2_name] = player_names
            {:ok, player1_id, _} = GameServer.join_game(rematch_game_id, player1_name)
            {:ok, player2_id, _} = GameServer.join_game(rematch_game_id, player2_name)

            # Select format for both players
            _ = GameServer.select_format(rematch_game_id, player1_id, format)
            _ = GameServer.select_format(rematch_game_id, player2_id, format)

            # Start the game immediately
            _ = GameServer.start_game(rematch_game_id)
            :ok

          {:error, {:already_started, _pid}} ->
            # Game already exists, that's fine
            :ok
        end

        # Broadcast rematch_ready event to redirect clients
        Phoenix.PubSub.broadcast(
          Oskol.PubSub,
          "game:#{game_id}",
          {:rematch_ready, rematch_game_id}
        )
      end
    end

    {:reply, :ok, socket}
  end

  # Handle PubSub broadcasts from GameServer
  @impl true
  def handle_info({:game_state_updated, game_server_state}, socket) do
    player_id = socket.assigns.player_id

    game_state_json =
      if game_server_state.game_state == nil do
        %{
          type: "lobby",
          connections: game_server_state.connections,
          lobby_status: Atom.to_string(game_server_state.lobby_status)
        }
      else
        # Get player-specific view from Gleam
        GleamEngine.get_player_view(game_server_state.game_state, player_id)
      end

    push(socket, "game_state_updated", %{game_state: game_state_json})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:action_failed, _player_id, reason}, socket) do
    # Log the failure but don't crash the channel
    Logger.warning("Action failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:rematch_ready, rematch_game_id}, socket) do
    # Notify client to navigate to rematch game
    push(socket, "rematch_ready", %{game_id: rematch_game_id})
    {:noreply, socket}
  end

  # Convert JSON card map to Card struct (from Elm)
  defp json_to_card(card_map) when is_map(card_map) do
    # Handle both string keys (from JSON) and atom keys (from Elixir)
    # Extract ID from client - we pass it through to Gleam for stable card identity
    id = Map.get(card_map, "id") || Map.get(card_map, :id)
    rank_str = Map.get(card_map, "rank") || Map.get(card_map, :rank)
    suit_str = Map.get(card_map, "suit") || Map.get(card_map, :suit)
    enhancement = Map.get(card_map, "enhancement") || Map.get(card_map, :enhancement)

    # Convert rank string to Gleam Rank atom
    # Elm now sends "two", "three", etc. instead of integers
    gleam_rank = if is_binary(rank_str), do: String.to_atom(rank_str), else: rank_str

    # Convert suit to Gleam Suit atom (already lowercase atoms)
    gleam_suit = if is_binary(suit_str), do: String.to_atom(suit_str), else: suit_str

    # Convert enhancement to Gleam Option(Enhancement)
    gleam_enhancement =
      case enhancement do
        nil -> :none
        %{"type" => "bonus_chips", "amount" => amount} -> {:some, {:bonus_chips, amount}}
        %{"type" => "bonus_mult", "amount" => amount} -> {:some, {:bonus_mult, amount}}
        %{type: "bonus_chips", amount: amount} -> {:some, {:bonus_chips, amount}}
        %{type: "bonus_mult", amount: amount} -> {:some, {:bonus_mult, amount}}
      end

    # Return Gleam Card tuple: {:card, id, rank, suit, enhancement}
    {:card, id, gleam_rank, gleam_suit, gleam_enhancement}
  end

  # Generate deterministic rematch game ID
  defp generate_rematch_id(current_id) do
    case Regex.run(~r/^(.+)-r(\d+)$/, current_id) do
      [_, base, num_str] ->
        num = String.to_integer(num_str)
        "#{base}-r#{num + 1}"

      nil ->
        "#{current_id}-r1"
    end
  end

  # Convert game configuration to format
  defp config_to_format(2, 1), do: :short
  defp config_to_format(3, 2), do: :standard
  defp config_to_format(5, 2), do: :extended
  # Default to standard if not a standard format
  defp config_to_format(_, _), do: :standard
end
