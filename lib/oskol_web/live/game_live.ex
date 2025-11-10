defmodule OskolWeb.GameLive do
  use OskolWeb, :live_view

  alias Oskol.Game
  alias Oskol.Poker.Card

  @impl true
  def mount(%{"id" => game_id}, _session, socket) do
    # Find or start game
    {:ok, _pid} = Game.find_or_start_game(game_id)

    # Subscribe to game updates
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

    # Get initial server state
    server_state = Game.get_server_state(game_id)

    # Check for disconnected players
    disconnected_players =
      server_state.connections
      |> Enum.filter(fn {_id, conn} -> not conn.connected end)
      |> Enum.map(fn {id, conn} -> {id, conn.name} end)

    socket =
      socket
      |> assign(
        game_id: game_id,
        server_state: server_state,
        player_id: nil,
        player_name: nil,
        joined: false,
        action_in_progress: false,
        selected_card_ids: [],
        viewing_results: false,
        viewing_round_summary: false,
        viewing_match_summary: false,
        disconnected_players: disconnected_players,
        your_card_sort: :rank,
        opponent_card_sort: :rank,
        error: nil
      )

    # Only auto-reconnect if this is the connected mount (not the initial disconnected render)
    # This prevents reconnecting with a temporary PID that will be discarded
    socket =
      if connected?(socket) do
        case disconnected_players do
          [{player_id, player_name}] ->
            case Game.rejoin_game(game_id, player_name, self()) do
              {:ok, ^player_id, new_state} ->
                # Check if there are hand results to show
                viewing_results =
                  new_state.game_state != nil and new_state.game_state.last_hand_results != nil

                socket
                |> assign(
                  player_id: player_id,
                  player_name: player_name,
                  joined: true,
                  server_state: new_state,
                  viewing_results: viewing_results,
                  error: nil
                )

              {:error, _reason} ->
                socket
            end

          _ ->
            socket
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("rejoin_as_player", %{"player_name" => name}, socket) do
    case Game.rejoin_game(socket.assigns.game_id, name, self()) do
      {:ok, player_id, new_state} ->
        # Check if there are hand results to show
        viewing_results =
          new_state.game_state != nil and new_state.game_state.last_hand_results != nil

        {:noreply,
         socket
         |> assign(
           player_id: player_id,
           player_name: name,
           joined: true,
           server_state: new_state,
           viewing_results: viewing_results,
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("join_game", %{"player_name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, error: "Name cannot be empty")}
    else
      case Game.join_game(socket.assigns.game_id, name, self()) do
        {:ok, player_id, new_state} ->
          {:noreply,
           socket
           |> assign(
             player_id: player_id,
             player_name: name,
             joined: true,
             server_state: new_state,
             error: nil
           )}

        {:error, :name_taken} ->
          # Name is taken - try to rejoin instead
          case Game.rejoin_game(socket.assigns.game_id, name, self()) do
            {:ok, player_id, new_state} ->
              {:noreply,
               socket
               |> assign(
                 player_id: player_id,
                 player_name: name,
                 joined: true,
                 server_state: new_state,
                 error: nil
               )}

            {:error, reason} ->
              {:noreply, assign(socket, error: format_error(reason))}
          end

        {:error, reason} ->
          {:noreply, assign(socket, error: format_error(reason))}
      end
    end
  end

  @impl true
  def handle_event("start_game", _params, socket) do
    case Game.start_game_session(socket.assigns.game_id) do
      {:ok, new_state} ->
        {:noreply, assign(socket, server_state: new_state, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("toggle_card", %{"id" => card_id}, socket) do
    selected_ids = socket.assigns.selected_card_ids

    new_selected_ids =
      if card_id in selected_ids do
        # Always allow deselecting
        List.delete(selected_ids, card_id)
      else
        # Only allow selecting if we haven't reached the limit of 5
        if length(selected_ids) < 5 do
          [card_id | selected_ids]
        else
          selected_ids
        end
      end

    {:noreply, assign(socket, selected_card_ids: new_selected_ids)}
  end

  @impl true
  def handle_event("lock_in_hand", _params, socket) do
    player_state = get_player_state(socket)
    selected_ids = socket.assigns.selected_card_ids

    # Find the actual cards by ID from hand_pile
    hand = Enum.filter(player_state.card_piles.hand_pile, fn card -> card.id in selected_ids end)

    # Validate we have 1-5 cards selected
    if length(hand) == 0 do
      {:noreply, assign(socket, error: "You must select at least 1 card")}
    else
      # Fire async action (server will validate cards are in hand)
      Game.player_lock_in_hand_async(
        socket.assigns.game_id,
        socket.assigns.player_id,
        hand
      )

      {:noreply, assign(socket, action_in_progress: true, selected_card_ids: [], error: nil)}
    end
  end

  @impl true
  def handle_event("dismiss_results", _params, socket) do
    {:noreply, assign(socket, viewing_results: false)}
  end

  @impl true
  def handle_event("undo_lock_in", _params, socket) do
    # Fire async action to unlock hand
    Game.player_unlock_hand_async(
      socket.assigns.game_id,
      socket.assigns.player_id
    )

    {:noreply, assign(socket, action_in_progress: true, selected_card_ids: [], error: nil)}
  end

  @impl true
  def handle_event("dismiss_round_summary", _params, socket) do
    game_state = socket.assigns.server_state.game_state

    if game_state.game_status == :game_over do
      {:noreply, assign(socket, viewing_round_summary: false, viewing_match_summary: true)}
    else
      {:noreply, assign(socket, viewing_round_summary: false)}
    end
  end

  @impl true
  def handle_event("mark_ready", _params, socket) do
    Game.mark_ready_for_next_round_async(socket.assigns.game_id, socket.assigns.player_id)
    {:noreply, assign(socket, action_in_progress: true)}
  end

  @impl true
  def handle_event("toggle_your_card_sort", _params, socket) do
    new_sort = if socket.assigns.your_card_sort == :rank, do: :suit, else: :rank
    {:noreply, assign(socket, your_card_sort: new_sort)}
  end

  @impl true
  def handle_event("toggle_opponent_card_sort", _params, socket) do
    new_sort = if socket.assigns.opponent_card_sort == :rank, do: :suit, else: :rank
    {:noreply, assign(socket, opponent_card_sort: new_sort)}
  end

  @impl true
  def handle_event("discard_cards", _params, socket) do
    player_state = get_player_state(socket)
    selected_ids = socket.assigns.selected_card_ids

    # Find the actual cards by ID from hand_pile
    cards = Enum.filter(player_state.card_piles.hand_pile, fn card -> card.id in selected_ids end)

    # Validate discard
    cond do
      player_state.discards_remaining == 0 ->
        {:noreply, assign(socket, error: "No discards remaining")}

      length(cards) == 0 ->
        {:noreply, assign(socket, error: "You must select at least 1 card to discard")}

      true ->
        # Fire async action (server will validate cards are in hand)
        Game.player_discard_cards_async(
          socket.assigns.game_id,
          socket.assigns.player_id,
          cards
        )

        {:noreply, assign(socket, action_in_progress: true, selected_card_ids: [], error: nil)}
    end
  end

  @impl true
  def handle_info({:game_state_updated, new_state}, socket) do
    # Check if we got new hand results - if so, show the results screen
    old_results =
      socket.assigns.server_state.game_state &&
        socket.assigns.server_state.game_state.last_hand_results

    new_results = new_state.game_state && new_state.game_state.last_hand_results

    viewing_results =
      if new_results != nil and new_results != old_results do
        true
      else
        socket.assigns.viewing_results
      end

    # Check if phase changed to :round_end - if so, show round summary
    old_phase =
      socket.assigns.server_state.game_state && socket.assigns.server_state.game_state.phase

    new_phase = new_state.game_state && new_state.game_state.phase

    viewing_round_summary =
      if new_phase == :round_end and old_phase != :round_end do
        true
      else
        socket.assigns.viewing_round_summary
      end

    # Update disconnected players list
    disconnected_players =
      new_state.connections
      |> Enum.filter(fn {_id, conn} -> not conn.connected end)
      |> Enum.map(fn {id, conn} -> {id, conn.name} end)

    {:noreply,
     socket
     |> assign(
       server_state: new_state,
       action_in_progress: false,
       viewing_results: viewing_results,
       viewing_round_summary: viewing_round_summary,
       disconnected_players: disconnected_players
     )
     |> clear_error()}
  end

  @impl true
  def handle_info({:action_failed, player_id, reason}, socket) do
    if player_id == socket.assigns.player_id do
      {:noreply,
       socket
       |> assign(action_in_progress: false, error: format_error(reason))
       |> put_flash(:error, format_error(reason))}
    else
      {:noreply, socket}
    end
  end

  # Helper functions

  defp get_player_state(socket) do
    if socket.assigns.server_state.game_state do
      socket.assigns.server_state.game_state.players[socket.assigns.player_id]
    else
      nil
    end
  end

  defp card_to_png_url(%Card{rank: rank, suit: suit}) do
    rank_str =
      case rank do
        14 -> "A"
        13 -> "K"
        12 -> "Q"
        11 -> "J"
        10 -> "0"
        n -> Integer.to_string(n)
      end

    suit_str =
      case suit do
        :hearts -> "H"
        :diamonds -> "D"
        :clubs -> "C"
        :spades -> "S"
      end

    "https://deckofcardsapi.com/static/img/#{rank_str}#{suit_str}.png"
  end

  defp format_error(:game_full), do: "Game is full"
  defp format_error(:name_taken), do: "Name already taken"
  defp format_error(:game_already_started), do: "Game already started"
  defp format_error(:not_enough_players), do: "Need 2 players to start"
  defp format_error(:game_not_started), do: "Game hasn't started yet"
  defp format_error(:player_not_found), do: "Player not found"
  defp format_error(:player_disconnected), do: "You are disconnected"
  defp format_error(:no_discards_remaining), do: "No discards remaining"
  defp format_error(:invalid_discard_count), do: "Invalid discard count (1-5 cards)"
  defp format_error({:unknown_action, _}), do: "Unknown action"
  defp format_error(other), do: "Error: #{inspect(other)}"

  defp clear_error(socket), do: assign(socket, error: nil)

  defp sort_cards(cards, :rank) do
    Enum.sort_by(cards, fn card -> {-card.rank, suit_order(card.suit)} end)
  end

  defp sort_cards(cards, :suit) do
    Enum.sort_by(cards, fn card -> {suit_order(card.suit), -card.rank} end)
  end

  defp suit_order(:spades), do: 0
  defp suit_order(:hearts), do: 1
  defp suit_order(:clubs), do: 2
  defp suit_order(:diamonds), do: 3

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-white p-8">
      <div class="max-w-6xl mx-auto">
        <%= if @error do %>
          <div class="bg-red-900 border border-red-700 rounded p-4 mb-4">
            {@error}
          </div>
        <% end %>

        <%= if not @joined do %>
          <!-- Join Lobby -->
          <div class="bg-gray-800 rounded-lg p-6">
            <h2 class="text-2xl font-bold mb-4">
              {if @server_state.game_state != nil, do: "Game in Progress", else: "Join Game"}
            </h2>

            <%= if length(@disconnected_players) > 0 do %>
              <div class="bg-purple-900 border border-purple-700 rounded p-4 mb-6">
                <p class="text-purple-200 font-bold">Reconnection Available</p>
                <p class="text-purple-100 text-sm mt-2">
                  A player disconnected. Click below to reconnect as them.
                </p>
              </div>
              <div class="mb-6">
                <div class="space-y-2">
                  <%= for {_player_id, player_name} <- @disconnected_players do %>
                    <button
                      phx-click="rejoin_as_player"
                      phx-value-player_name={player_name}
                      class="w-full bg-purple-600 hover:bg-purple-700 px-6 py-3 rounded font-bold text-lg transition-colors"
                    >
                      Reconnect as {player_name}
                    </button>
                  <% end %>
                </div>
              </div>
              <%= if @server_state.game_state == nil do %>
                <div class="border-t border-gray-700 pt-6 mb-4">
                  <h3 class="text-lg font-bold mb-4">Or join as a new player:</h3>
                </div>
              <% end %>
            <% else %>
              <%= if @server_state.game_state != nil do %>
                <div class="bg-gray-700 border border-gray-600 rounded p-4 mb-4">
                  <p class="text-gray-300">
                    This game is full and all players are connected. You cannot join or spectate at this time.
                  </p>
                </div>
              <% end %>
            <% end %>

            <%= if @server_state.game_state == nil do %>
              <form phx-submit="join_game" class="flex gap-4">
                <input
                  type="text"
                  name="player_name"
                  placeholder="Enter your name"
                  class="flex-1 bg-gray-700 rounded px-4 py-2 text-white"
                  autocomplete="off"
                  autofocus
                />
                <button
                  type="submit"
                  class="bg-blue-600 hover:bg-blue-700 px-6 py-2 rounded font-bold"
                >
                  Join
                </button>
              </form>
            <% end %>

            <%= if map_size(@server_state.connections) > 0 do %>
              <div class="mt-6">
                <h3 class="text-lg font-bold mb-2">Players:</h3>
                <ul class="space-y-2">
                  <%= for {_id, conn} <- @server_state.connections do %>
                    <li class="flex items-center gap-2">
                      <div class={[
                        "w-3 h-3 rounded-full",
                        if(conn.connected, do: "bg-green-500", else: "bg-gray-500")
                      ]}>
                      </div>
                      <span class="text-gray-300">{conn.name}</span>
                      <span class="text-xs text-gray-500">
                        {if conn.connected, do: "(online)", else: "(offline)"}
                      </span>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        <% else %>
          <!-- Lobby / Game UI -->
          <%= if @server_state.game_state == nil do %>
            <!-- Waiting to Start -->
            <div class="bg-gray-800 rounded-lg p-6">
              <h2 class="text-2xl font-bold mb-4">Lobby</h2>
              <p class="mb-4">You are: <span class="text-blue-400">{@player_name}</span></p>

              <div class="mb-6">
                <h3 class="text-lg font-bold mb-2">Players:</h3>
                <ul class="space-y-2">
                  <%= for {_id, conn} <- @server_state.connections do %>
                    <li class="flex items-center gap-2">
                      <div class={[
                        "w-3 h-3 rounded-full",
                        if(conn.connected, do: "bg-green-500", else: "bg-gray-500")
                      ]}>
                      </div>
                      <span class="text-gray-300">{conn.name}</span>
                      <span class="text-xs text-gray-500">
                        {if conn.connected, do: "(online)", else: "(offline)"}
                      </span>
                    </li>
                  <% end %>
                </ul>
              </div>

              <%= if @server_state.lobby_status == :ready_to_start do %>
                <button
                  phx-click="start_game"
                  class="bg-green-600 hover:bg-green-700 px-6 py-3 rounded font-bold text-lg"
                >
                  Start Game!
                </button>
              <% else %>
                <p class="text-yellow-400">Waiting for another player...</p>
              <% end %>
            </div>
          <% else %>
            <!-- In Game -->
            <% game_state = @server_state.game_state %>
            <% player_state = game_state.players[@player_id] %>
            <% opponent_id = Enum.find(Map.keys(game_state.players), &(&1 != @player_id)) %>
            <% opponent_state = if opponent_id, do: game_state.players[opponent_id], else: nil %>
            <% opponent_name = if opponent_id, do: game_state.player_names[opponent_id], else: nil %>
            <% player_connected = @server_state.connections[@player_id].connected %>
            <% opponent_connected =
              if opponent_id, do: @server_state.connections[opponent_id].connected, else: false %>
            
    <!-- Game Info -->
            <div class="grid grid-cols-3 gap-4 mb-8">
              <div class="bg-gray-800 rounded-lg p-4">
                <div class="text-gray-400 text-sm">Round</div>
                <div class="text-2xl font-bold">{game_state.round_number}</div>
              </div>
              <div class="bg-gray-800 rounded-lg p-4">
                <div class="text-gray-400 text-sm">Blind Target</div>
                <div class="text-2xl font-bold text-yellow-400">{game_state.blind_target}</div>
              </div>
              <div class="bg-gray-800 rounded-lg p-4">
                <div class="text-gray-400 text-sm">Phase</div>
                <div class="text-2xl font-bold">
                  <%= case game_state.phase do %>
                    <% :playing -> %>
                      Playing
                    <% :round_end -> %>
                      Round End
                  <% end %>
                </div>
              </div>
            </div>
            
    <!-- Opponent Info -->
            <%= if opponent_state && game_state.phase != :round_end do %>
              <div class="bg-gray-800 rounded-lg p-6 mb-6">
                <!-- Single row: Name on left, Stats and Score on right -->
                <div class="flex items-center justify-between mb-4">
                  <!-- Left: Status dot + Name -->
                  <div class="flex items-center gap-2">
                    <div class={[
                      "w-3 h-3 rounded-full",
                      if(opponent_connected, do: "bg-green-500", else: "bg-gray-500")
                    ]}>
                    </div>
                    <h3 class="text-xl font-bold text-blue-400">{opponent_name}</h3>
                  </div>
                  
    <!-- Right: Icons with stats + Score -->
                  <div class="flex items-center gap-4">
                    <!-- Hands remaining -->
                    <div class="flex items-center gap-1">
                      <.icon name="hero-play" class="w-5 h-5" />
                      <span class="text-lg font-bold">{opponent_state.hands_remaining}</span>
                    </div>
                    
    <!-- Discards remaining -->
                    <div class="flex items-center gap-1">
                      <.icon name="hero-trash" class="w-5 h-5" />
                      <span class="text-lg font-bold">{opponent_state.discards_remaining}</span>
                    </div>
                    
    <!-- Lives as hearts -->
                    <div class="flex items-center gap-1">
                      <.icon name="hero-heart" class="w-5 h-5" />
                      <span class="text-lg font-bold">{opponent_state.lives}</span>
                    </div>
                    
    <!-- Score -->
                    <div class="text-2xl font-bold text-green-400">
                      {opponent_state.current_round_score}
                    </div>
                  </div>
                </div>

                <div class="mt-4">
                  <div class="flex flex-wrap gap-4 mb-2">
                    <%= for card <- sort_cards(opponent_state.card_piles.hand_pile, @opponent_card_sort) do %>
                      <div class="w-28 h-40 rounded overflow-hidden">
                        <img src={card_to_png_url(card)} class="w-full h-full object-cover" />
                      </div>
                    <% end %>
                  </div>
                  <div class="flex items-center justify-start">
                    <button
                      phx-click="toggle_opponent_card_sort"
                      class="text-sm px-3 py-1 bg-gray-700 hover:bg-gray-600 rounded transition-colors"
                    >
                      <div class="flex items-center gap-2">
                        <.icon name="hero-arrows-up-down" class="w-4 h-4" />
                        <span>{if @opponent_card_sort == :rank, do: "Rank", else: "Suit"}</span>
                      </div>
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
            
    <!-- Round Summary -->
            <%= if @viewing_round_summary and game_state.phase == :round_end do %>
              <div class="bg-gray-800 rounded-lg p-6 mb-6">
                <h3 class="text-2xl font-bold mb-6 text-center text-yellow-400">
                  Round {game_state.round_number} Complete!
                </h3>

                <div class="grid grid-cols-2 gap-6 mb-6">
                  <!-- Your Summary -->
                  <div class="bg-gray-700 rounded-lg p-6">
                    <h4 class="text-lg font-bold mb-4 text-blue-400">
                      {game_state.player_names[@player_id]}
                    </h4>
                    <div class="space-y-4">
                      <div>
                        <div class="text-gray-400 text-sm">Final Score</div>
                        <div class="text-3xl font-bold text-green-400">
                          {player_state.current_round_score}
                        </div>
                      </div>
                      <div>
                        <div class="text-gray-400 text-sm">Blind Target</div>
                        <div class="text-2xl font-bold text-yellow-400">
                          {game_state.blind_target}
                        </div>
                      </div>
                      <div>
                        <div class="text-gray-400 text-sm">Result</div>
                        <%= if player_state.current_round_score >= game_state.blind_target do %>
                          <div class="text-2xl font-bold text-green-400">✓ Blind Cleared!</div>
                        <% else %>
                          <div class="text-2xl font-bold text-red-400">✗ Blind Failed (-1 Life)</div>
                        <% end %>
                      </div>
                    </div>
                    
    <!-- Hands Played -->
                    <div class="mt-6">
                      <div class="text-gray-400 text-sm mb-3">Hands Played</div>
                      <div class="space-y-3">
                        <%= for {hand_results, index} <- Enum.with_index(game_state.round_hand_history, 1) do %>
                          <% my_result = hand_results[@player_id] %>
                          <div class="bg-gray-800 rounded p-3">
                            <div class="flex items-center justify-between mb-2">
                              <div class="text-xs text-gray-500">Hand {index}</div>
                              <div class="text-sm font-bold text-green-400">+{my_result.score}</div>
                            </div>
                            <div class="flex gap-1 mb-2">
                              <%= for card <- my_result.hand do %>
                                <div class="w-12 h-16 rounded overflow-hidden">
                                  <img src={card_to_png_url(card)} class="w-full h-full object-cover" />
                                </div>
                              <% end %>
                            </div>
                            <div class="text-xs text-gray-400">
                              {my_result.hand_type
                              |> Atom.to_string()
                              |> String.replace("_", " ")
                              |> String.upcase()}
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                  
    <!-- Opponent's Summary -->
                  <div class="bg-gray-700 rounded-lg p-6">
                    <h4 class="text-lg font-bold mb-4 text-red-400">
                      {opponent_name}
                    </h4>
                    <div class="space-y-4">
                      <div>
                        <div class="text-gray-400 text-sm">Final Score</div>
                        <div class="text-3xl font-bold text-green-400">
                          {opponent_state.current_round_score}
                        </div>
                      </div>
                      <div>
                        <div class="text-gray-400 text-sm">Blind Target</div>
                        <div class="text-2xl font-bold text-yellow-400">
                          {game_state.blind_target}
                        </div>
                      </div>
                      <div>
                        <div class="text-gray-400 text-sm">Result</div>
                        <%= if opponent_state.current_round_score >= game_state.blind_target do %>
                          <div class="text-2xl font-bold text-green-400">✓ Blind Cleared!</div>
                        <% else %>
                          <div class="text-2xl font-bold text-red-400">✗ Blind Failed (-1 Life)</div>
                        <% end %>
                      </div>
                    </div>
                    
    <!-- Hands Played -->
                    <div class="mt-6">
                      <div class="text-gray-400 text-sm mb-3">Hands Played</div>
                      <div class="space-y-3">
                        <%= for {hand_results, index} <- Enum.with_index(game_state.round_hand_history, 1) do %>
                          <% opponent_result = hand_results[opponent_id] %>
                          <div class="bg-gray-800 rounded p-3">
                            <div class="flex items-center justify-between mb-2">
                              <div class="text-xs text-gray-500">Hand {index}</div>
                              <div class="text-sm font-bold text-green-400">
                                +{opponent_result.score}
                              </div>
                            </div>
                            <div class="flex gap-1 mb-2">
                              <%= for card <- opponent_result.hand do %>
                                <div class="w-12 h-16 rounded overflow-hidden">
                                  <img src={card_to_png_url(card)} class="w-full h-full object-cover" />
                                </div>
                              <% end %>
                            </div>
                            <div class="text-xs text-gray-400">
                              {opponent_result.hand_type
                              |> Atom.to_string()
                              |> String.replace("_", " ")
                              |> String.upcase()}
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="text-center">
                  <button
                    phx-click="dismiss_round_summary"
                    class="bg-purple-600 hover:bg-purple-700 px-8 py-4 rounded font-bold text-xl"
                  >
                    <%= if game_state.game_status == :game_over do %>
                      View Match Summary
                    <% else %>
                      Continue to Shop
                    <% end %>
                  </button>
                </div>
              </div>
            <% end %>
            
    <!-- Match Summary (Game Over) -->
            <%= if @viewing_match_summary and game_state.game_status == :game_over do %>
              <div class="bg-gray-800 rounded-lg p-6 mb-6">
                <h3 class="text-3xl font-bold mb-8 text-center text-yellow-400">
                  Match Complete!
                </h3>

                <div class="grid grid-cols-2 gap-6 mb-8">
                  <!-- Your Result -->
                  <div class={[
                    "rounded-lg p-8",
                    if(game_state.winner_id == @player_id,
                      do: "bg-green-800 border-4 border-green-400",
                      else: "bg-gray-700"
                    )
                  ]}>
                    <h4 class="text-2xl font-bold mb-6 text-center text-blue-400">
                      {game_state.player_names[@player_id]}
                    </h4>
                    <%= if game_state.winner_id == @player_id do %>
                      <div class="text-4xl font-bold text-green-400 text-center mb-6">
                        🏆 WINNER!
                      </div>
                    <% end %>
                    <div class="flex justify-center items-center gap-2 mb-4">
                      <% lives = max(0, player_state.lives) %>
                      <%= if lives > 0 do %>
                        <%= for _i <- 1..lives do %>
                          <.icon name="hero-heart" class="w-12 h-12 text-red-500" />
                        <% end %>
                      <% end %>
                      <%= if lives < 3 do %>
                        <%= for _i <- 1..(3 - lives) do %>
                          <.icon name="hero-heart" class="w-12 h-12 text-gray-600" />
                        <% end %>
                      <% end %>
                    </div>
                    <div class="text-center text-gray-400 text-sm">
                      {player_state.lives} {if player_state.lives == 1, do: "Life", else: "Lives"} Remaining
                    </div>
                  </div>
                  
    <!-- Opponent's Result -->
                  <div class={[
                    "rounded-lg p-8",
                    if(game_state.winner_id == opponent_id,
                      do: "bg-green-800 border-4 border-green-400",
                      else: "bg-gray-700"
                    )
                  ]}>
                    <h4 class="text-2xl font-bold mb-6 text-center text-red-400">
                      {opponent_name}
                    </h4>
                    <%= if game_state.winner_id == opponent_id do %>
                      <div class="text-4xl font-bold text-green-400 text-center mb-6">
                        🏆 WINNER!
                      </div>
                    <% end %>
                    <div class="flex justify-center items-center gap-2 mb-4">
                      <% lives = max(0, opponent_state.lives) %>
                      <%= if lives > 0 do %>
                        <%= for _i <- 1..lives do %>
                          <.icon name="hero-heart" class="w-12 h-12 text-red-500" />
                        <% end %>
                      <% end %>
                      <%= if lives < 3 do %>
                        <%= for _i <- 1..(3 - lives) do %>
                          <.icon name="hero-heart" class="w-12 h-12 text-gray-600" />
                        <% end %>
                      <% end %>
                    </div>
                    <div class="text-center text-gray-400 text-sm">
                      {opponent_state.lives} {if opponent_state.lives == 1, do: "Life", else: "Lives"} Remaining
                    </div>
                  </div>
                </div>

                <div class="text-center text-gray-500">
                  Game Over - Rounds Completed: {game_state.round_number}
                </div>
              </div>
            <% end %>
            
    <!-- Shop -->
            <%= if game_state.phase == :round_end and not @viewing_round_summary and not @viewing_match_summary and game_state.game_status != :game_over do %>
              <div class="bg-gray-800 rounded-lg p-6 mb-6">
                <h3 class="text-2xl font-bold mb-6 text-center text-cyan-400">Shop</h3>

                <div class="bg-gray-700 rounded-lg p-8 mb-6 text-center">
                  <p class="text-gray-400 text-xl mb-4">Shop Coming Soon!</p>
                  <p class="text-gray-500 text-sm">Click Ready to start the next round</p>
                </div>

                <div class="flex flex-col items-center gap-4">
                  <div class="flex gap-8 text-lg">
                    <div class="flex items-center gap-2">
                      <span class="text-blue-400">{game_state.player_names[@player_id]}:</span>
                      <%= if player_state.ready_for_next_round do %>
                        <span class="text-green-400 font-bold">✓ Ready</span>
                      <% else %>
                        <span class="text-gray-400">Not Ready</span>
                      <% end %>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="text-red-400">{opponent_name}:</span>
                      <%= if opponent_state.ready_for_next_round do %>
                        <span class="text-green-400 font-bold">✓ Ready</span>
                      <% else %>
                        <span class="text-gray-400">Not Ready</span>
                      <% end %>
                    </div>
                  </div>

                  <button
                    phx-click="mark_ready"
                    disabled={@action_in_progress or player_state.ready_for_next_round}
                    class={[
                      "px-8 py-4 rounded font-bold text-xl",
                      if(@action_in_progress or player_state.ready_for_next_round,
                        do: "bg-gray-600 cursor-not-allowed",
                        else: "bg-green-600 hover:bg-green-700"
                      )
                    ]}
                  >
                    <%= cond do %>
                      <% player_state.ready_for_next_round -> %>
                        Ready! Waiting for opponent...
                      <% @action_in_progress -> %>
                        Marking Ready...
                      <% true -> %>
                        I'm Ready
                    <% end %>
                  </button>
                </div>
              </div>
            <% end %>
            
    <!-- Hand Results -->
            <%= if @viewing_results and game_state.last_hand_results != nil and game_state.phase != :round_end do %>
              <div class="bg-gray-800 rounded-lg p-6 mb-6">
                <h3 class="text-2xl font-bold mb-6 text-center text-yellow-400">Hand Results!</h3>

                <div class="grid grid-cols-2 gap-6 mb-6">
                  <!-- Your Result -->
                  <div class="bg-gray-700 rounded-lg p-6">
                    <h4 class="text-lg font-bold mb-4 text-blue-400">
                      Your Hand - {game_state.player_names[@player_id]}
                    </h4>
                    <% my_result = game_state.last_hand_results[@player_id] %>
                    <div class="flex gap-2 mb-4">
                      <%= for card <- my_result.hand do %>
                        <div class="w-24 h-32 rounded overflow-hidden">
                          <img src={card_to_png_url(card)} class="w-full h-full object-cover" />
                        </div>
                      <% end %>
                    </div>
                    <div class="mt-4">
                      <div class="text-gray-400 text-sm">Hand Type</div>
                      <div class="text-xl font-bold">
                        {my_result.hand_type
                        |> Atom.to_string()
                        |> String.replace("_", " ")
                        |> String.upcase()}
                      </div>
                    </div>
                    <div class="mt-2">
                      <div class="text-gray-400 text-sm">Score</div>
                      <div class="text-3xl font-bold text-green-400">{my_result.score}</div>
                    </div>
                  </div>
                  
    <!-- Opponent's Result -->
                  <div class="bg-gray-700 rounded-lg p-6">
                    <h4 class="text-lg font-bold mb-4 text-red-400">
                      Opponent's Hand - {opponent_name}
                    </h4>
                    <% opponent_result = game_state.last_hand_results[opponent_id] %>
                    <div class="flex gap-2 mb-4">
                      <%= for card <- opponent_result.hand do %>
                        <div class="w-24 h-32 rounded overflow-hidden">
                          <img src={card_to_png_url(card)} class="w-full h-full object-cover" />
                        </div>
                      <% end %>
                    </div>
                    <div class="mt-4">
                      <div class="text-gray-400 text-sm">Hand Type</div>
                      <div class="text-xl font-bold">
                        {opponent_result.hand_type
                        |> Atom.to_string()
                        |> String.replace("_", " ")
                        |> String.upcase()}
                      </div>
                    </div>
                    <div class="mt-2">
                      <div class="text-gray-400 text-sm">Score</div>
                      <div class="text-3xl font-bold text-green-400">{opponent_result.score}</div>
                    </div>
                  </div>
                </div>

                <div class="text-center">
                  <button
                    phx-click="dismiss_results"
                    class="bg-purple-600 hover:bg-purple-700 px-8 py-4 rounded font-bold text-xl"
                  >
                    Continue to Next Hand
                  </button>
                </div>
              </div>
            <% else %>
              <%= if game_state.phase != :round_end do %>
                
    <!-- Player Section with Cards -->
                <div class="bg-gray-800 rounded-lg p-6">
                  <% # Compute selected card IDs based on locked_in_hand or local state
                  selected_card_ids =
                    if player_state.locked_in_hand != nil do
                      # Use locked_in_hand card IDs as selected
                      Enum.map(player_state.locked_in_hand, fn card -> card.id end)
                    else
                      @selected_card_ids
                    end

                  is_locked_in = player_state.locked_in_hand != nil %>
                  <!-- Single row: Name on left, Stats and Score on right -->
                  <div class="flex items-center justify-between mb-6">
                    <!-- Left: Status dot + Name -->
                    <div class="flex items-center gap-2">
                      <div class={[
                        "w-3 h-3 rounded-full",
                        if(player_connected, do: "bg-green-500", else: "bg-gray-500")
                      ]}>
                      </div>
                      <h3 class="text-xl font-bold text-blue-400">{@player_name}</h3>
                    </div>
                    
    <!-- Right: Icons with stats + Score -->
                    <div class="flex items-center gap-4">
                      <!-- Hands remaining -->
                      <div class="flex items-center gap-1">
                        <.icon name="hero-play" class="w-5 h-5" />
                        <span class="text-lg font-bold">{player_state.hands_remaining}</span>
                      </div>
                      
    <!-- Discards remaining -->
                      <div class="flex items-center gap-1">
                        <.icon name="hero-trash" class="w-5 h-5" />
                        <span class="text-lg font-bold">{player_state.discards_remaining}</span>
                      </div>
                      
    <!-- Lives as hearts -->
                      <div class="flex items-center gap-1">
                        <.icon name="hero-heart" class="w-5 h-5" />
                        <span class="text-lg font-bold">{player_state.lives}</span>
                      </div>
                      
    <!-- Score -->
                      <div class="text-2xl font-bold text-green-400">
                        {player_state.current_round_score}
                      </div>
                    </div>
                  </div>
                  
    <!-- Card Selection -->
                  <div class="flex flex-wrap gap-4 mb-6">
                    <% # Sort cards by rank or suit
                    sorted_cards =
                      player_state.card_piles.hand_pile
                      |> Enum.sort_by(fn card ->
                        case @your_card_sort do
                          :rank -> {-card.rank, suit_order(card.suit)}
                          :suit -> {suit_order(card.suit), -card.rank}
                        end
                      end) %>
                    <%= for card <- sorted_cards do %>
                      <% # Check if this card is selected by ID
                      selected = card.id in selected_card_ids %>
                      <% at_limit = length(selected_card_ids) >= 5 %>
                      <button
                        phx-click="toggle_card"
                        phx-value-id={card.id}
                        disabled={@action_in_progress or (at_limit and not selected) or is_locked_in}
                        class={[
                          "transition-all w-28 h-40 rounded overflow-hidden",
                          if(selected, do: "-translate-y-4", else: ""),
                          if((at_limit and not selected) or is_locked_in,
                            do: "opacity-50 cursor-not-allowed",
                            else: ""
                          )
                        ]}
                      >
                        <img
                          src={card_to_png_url(card)}
                          class="w-full h-full object-cover"
                        />
                      </button>
                    <% end %>
                  </div>

                  <div class="flex gap-4 justify-between items-center">
                    <button
                      phx-click="toggle_your_card_sort"
                      class="text-sm px-3 py-1 bg-gray-700 hover:bg-gray-600 rounded transition-colors"
                    >
                      <div class="flex items-center gap-2">
                        <.icon name="hero-arrows-up-down" class="w-4 h-4" />
                        <span>{if @your_card_sort == :rank, do: "Rank", else: "Suit"}</span>
                      </div>
                    </button>

                    <div class="flex gap-4">
                      <button
                        phx-click="discard_cards"
                        disabled={
                          @action_in_progress or length(selected_card_ids) == 0 or
                            player_state.discards_remaining == 0 or is_locked_in
                        }
                        class={[
                          "px-3 py-1 rounded text-sm transition-colors",
                          if(
                            @action_in_progress or length(selected_card_ids) == 0 or
                              player_state.discards_remaining == 0 or is_locked_in,
                            do: "bg-gray-600 cursor-not-allowed",
                            else: "bg-blue-600 hover:bg-blue-700"
                          )
                        ]}
                      >
                        <%= if @action_in_progress do %>
                          Discarding...
                        <% else %>
                          <div class="flex items-center gap-2">
                            <.icon name="hero-trash" class="w-4 h-4" />
                            <span>Discard</span>
                          </div>
                        <% end %>
                      </button>

                      <%= if is_locked_in do %>
                        <button
                          phx-click="undo_lock_in"
                          disabled={@action_in_progress}
                          class={[
                            "px-3 py-1 rounded text-sm transition-colors",
                            if(
                              @action_in_progress,
                              do: "bg-gray-600 cursor-not-allowed",
                              else: "bg-yellow-600 hover:bg-yellow-700"
                            )
                          ]}
                        >
                          <%= if @action_in_progress do %>
                            Undoing...
                          <% else %>
                            <div class="flex items-center gap-2">
                              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                              <span>Undo</span>
                            </div>
                          <% end %>
                        </button>
                      <% else %>
                        <button
                          phx-click="lock_in_hand"
                          disabled={@action_in_progress or length(selected_card_ids) == 0}
                          class={[
                            "px-3 py-1 rounded text-sm transition-colors",
                            if(
                              @action_in_progress or length(selected_card_ids) == 0,
                              do: "bg-gray-600 cursor-not-allowed",
                              else: "bg-green-600 hover:bg-green-700"
                            )
                          ]}
                        >
                          <%= if @action_in_progress do %>
                            Playing...
                          <% else %>
                            <div class="flex items-center gap-2">
                              <.icon name="hero-play" class="w-4 h-4" />
                              <span>Play</span>
                            </div>
                          <% end %>
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
