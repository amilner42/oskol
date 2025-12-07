defmodule OskolWeb.LandingLive do
  use OskolWeb, :live_view

  alias Oskol.Game
  alias Oskol.Game.DevCodes

  @is_dev Mix.env() == :dev

  @impl true
  def mount(params, _session, socket) do
    # Check for ?game= query param
    game_name = params["game"] || ""

    # Initial step - will be updated in handle_params once connected
    step = if game_name != "", do: :player_name, else: :game_name

    {:ok,
     assign(socket,
       step: step,
       game_name: game_name,
       player_name: "",
       dev_code: "",
       valid_dev_codes: [],
       invalid_dev_codes: [],
       error: nil,
       inviter_name: nil,
       # Game connection state (used when in :joining or :lobby steps)
       player_id: nil,
       server_state: nil,
       selected_format: nil,
       disconnected_players: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Handle URL changes (e.g., from push_patch)
    game_name = params["game"] || ""
    name_from_url = params["name"]

    # Set Open Graph meta tags for invite links
    socket =
      if game_name != "" && !name_from_url do
        set_invite_meta_tags(socket, game_name)
      else
        socket
      end

    socket =
      cond do
        # No game param - show game name input
        game_name == "" ->
          assign(socket, step: :game_name, game_name: "")

        # Already past the player_name step (in joining or lobby) - don't change
        socket.assigns.step in [:joining, :lobby] ->
          socket

        # Have both game and name params - try to auto-rejoin
        connected?(socket) && name_from_url && name_from_url != "" ->
          auto_rejoin_lobby(socket, game_name, name_from_url)

        # Have a game param and connected - check for disconnected players
        connected?(socket) ->
          check_game_for_reconnect(socket, game_name)

        # Have a game param but not connected yet - show player name (will recheck on connect)
        true ->
          assign(socket, step: :player_name, game_name: game_name)
      end

    {:noreply, socket}
  end

  # Set Open Graph meta tags for invite links
  defp set_invite_meta_tags(socket, game_name) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        server_state = Game.get_server_state(game_name)

        # Get the first connected player's name (the inviter)
        inviter_name =
          server_state.connections
          |> Enum.find(fn {_id, conn} -> conn.connected end)
          |> case do
            {_id, conn} -> conn.name
            nil -> nil
          end

        if inviter_name do
          assign(socket,
            og_title: "#{inviter_name} challenged you to Oskol Poker",
            og_description: "Accept the challenge to engage in poker warfare"
          )
        else
          socket
        end

      :not_found ->
        socket
    end
  end

  # Auto-rejoin lobby when name is in URL
  defp auto_rejoin_lobby(socket, game_name, player_name) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        # Subscribe to game updates
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_name}")

        # Try to rejoin first (for reconnecting players)
        case Game.rejoin_game(game_name, player_name, self()) do
          {:ok, player_id, new_state} ->
            # Check if game already started - redirect to game
            if new_state.game_state != nil do
              push_navigate(socket, to: ~p"/#{game_name}?name=#{player_name}")
            else
              assign(socket,
                step: :lobby,
                game_name: game_name,
                player_name: player_name,
                player_id: player_id,
                server_state: new_state,
                selected_format: Map.get(new_state.format_selections, player_id),
                error: nil
              )
            end

          {:error, _reason} ->
            # Couldn't rejoin - try joining as a new player if game is still in lobby
            server_state = Game.get_server_state(game_name)

            if server_state.game_state == nil do
              # Game is still in lobby - try to join as new player
              case Game.join_game(game_name, player_name, self()) do
                {:ok, player_id, new_state} ->
                  socket
                  |> assign(
                    step: :lobby,
                    game_name: game_name,
                    player_name: player_name,
                    player_id: player_id,
                    server_state: new_state,
                    selected_format: nil,
                    error: nil
                  )
                  |> push_patch(to: ~p"/?game=#{game_name}&name=#{player_name}")

                {:error, _join_reason} ->
                  # Join also failed - fall back to reconnect check
                  check_game_for_reconnect(socket, game_name, player_name)
              end
            else
              # Game in progress - fall back to reconnect check
              check_game_for_reconnect(socket, game_name, player_name)
            end
        end

      :not_found ->
        # Game doesn't exist yet - create it and join with the name from URL
        # This handles the rematch flow where both players have names in URL
        {:ok, _pid} = Game.find_or_start_game(game_name)

        # Subscribe to game updates
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_name}")

        # Join the game with the name from URL
        case Game.join_game(game_name, player_name, self()) do
          {:ok, player_id, new_state} ->
            socket
            |> assign(
              step: :lobby,
              game_name: game_name,
              player_name: player_name,
              player_id: player_id,
              server_state: new_state,
              selected_format: nil,
              error: nil
            )
            |> push_patch(to: ~p"/?game=#{game_name}&name=#{player_name}")

          {:error, reason} ->
            assign(socket, step: :player_name, game_name: game_name, error: format_error(reason))
        end
    end
  end

  # Check if the game has disconnected players and show reconnect screen
  # Optional name_from_url parameter for auto-rejoin attempt
  defp check_game_for_reconnect(socket, game_name, name_from_url \\ nil) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        server_state = Game.get_server_state(game_name)

        # Subscribe to game updates
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_name}")

        # Get inviter name (first connected player)
        inviter_name =
          server_state.connections
          |> Enum.find(fn {_id, conn} -> conn.connected end)
          |> case do
            {_id, conn} -> conn.name
            nil -> nil
          end

        # Check for disconnected players
        disconnected_players =
          server_state.connections
          |> Enum.filter(fn {_id, conn} -> not conn.connected end)
          |> Enum.map(fn {id, conn} -> {id, conn.name} end)

        # If we have a name from URL and it matches a disconnected player, auto-rejoin
        matching_disconnected =
          if name_from_url do
            Enum.find(disconnected_players, fn {_id, name} -> name == name_from_url end)
          end

        cond do
          # Auto-rejoin if name from URL matches a disconnected player
          matching_disconnected != nil ->
            case Game.rejoin_game(game_name, name_from_url, self()) do
              {:ok, player_id, new_state} ->
                if new_state.game_state != nil do
                  push_navigate(socket, to: ~p"/#{game_name}?name=#{name_from_url}")
                else
                  assign(socket,
                    step: :lobby,
                    game_name: game_name,
                    player_name: name_from_url,
                    player_id: player_id,
                    server_state: new_state,
                    selected_format: Map.get(new_state.format_selections, player_id),
                    error: nil
                  )
                end

              {:error, _reason} ->
                # Still failed - show joining screen
                assign(socket,
                  step: :joining,
                  game_name: game_name,
                  server_state: server_state,
                  disconnected_players: disconnected_players
                )
            end

          # Game in progress - show join screen with reconnect options
          server_state.game_state != nil ->
            assign(socket,
              step: :joining,
              game_name: game_name,
              server_state: server_state,
              disconnected_players: disconnected_players
            )

          # Has disconnected players in lobby - show reconnect screen
          length(disconnected_players) > 0 ->
            assign(socket,
              step: :joining,
              game_name: game_name,
              server_state: server_state,
              disconnected_players: disconnected_players
            )

          # No disconnected players - show player name input
          true ->
            assign(socket, step: :player_name, game_name: game_name, inviter_name: inviter_name)
        end

      :not_found ->
        # Game doesn't exist yet - show player name input
        assign(socket, step: :player_name, game_name: game_name, inviter_name: nil)
    end
  end

  @impl true
  def handle_event("new_game", %{"player_name" => player_name}, socket) do
    player_name = String.trim(player_name)

    if player_name == "" do
      {:noreply, assign(socket, error: "Please enter a display name")}
    else
      # Generate a random 6-character game ID
      game_id = generate_game_id()

      # Start the game and join immediately
      {:ok, _pid} = Game.find_or_start_game(game_id)

      # Subscribe to game updates
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      # Join the game
      case Game.join_game(game_id, player_name, self()) do
        {:ok, player_id, new_state} ->
          {:noreply,
           socket
           |> assign(
             step: :lobby,
             game_name: game_id,
             player_name: player_name,
             player_id: player_id,
             server_state: new_state,
             selected_format: nil,
             error: nil
           )
           |> push_patch(to: ~p"/?game=#{game_id}&name=#{player_name}")}

        {:error, reason} ->
          {:noreply, assign(socket, error: format_error(reason))}
      end
    end
  end

  # Generate a random URL-safe game ID
  defp generate_game_id do
    :crypto.strong_rand_bytes(6)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 6)
    |> String.downcase()
  end

  @impl true
  def handle_event("submit_player_name", %{"player_name" => player_name}, socket) do
    player_name = String.trim(player_name)

    if player_name == "" do
      {:noreply, assign(socket, error: "Please enter a display name")}
    else
      # Connect to game server
      game_id = socket.assigns.game_name
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
          player_name: player_name,
          server_state: server_state,
          disconnected_players: disconnected_players
        )

      # Try to join the game
      case Game.join_game(game_id, player_name, self()) do
        {:ok, player_id, new_state} ->
          {:noreply,
           socket
           |> assign(
             step: :lobby,
             player_id: player_id,
             server_state: new_state,
             selected_format: nil,
             error: nil
           )
           |> push_patch(to: ~p"/?game=#{game_id}&name=#{player_name}")}

        {:error, :name_taken} ->
          # Name taken - try to rejoin
          case Game.rejoin_game(game_id, player_name, self()) do
            {:ok, player_id, new_state} ->
              # Check if game already started
              if new_state.game_state != nil do
                {:noreply, push_navigate(socket, to: ~p"/#{game_id}?name=#{player_name}")}
              else
                {:noreply,
                 socket
                 |> assign(
                   step: :lobby,
                   player_id: player_id,
                   server_state: new_state,
                   selected_format: Map.get(new_state.format_selections, player_id),
                   error: nil
                 )
                 |> push_patch(to: ~p"/?game=#{game_id}&name=#{player_name}")}
              end

            {:error, _reason} ->
              {:noreply,
               assign(socket,
                 step: :joining,
                 error: "Name already taken by another player"
               )}
          end

        {:error, :game_full} ->
          {:noreply,
           assign(socket,
             step: :joining,
             error: nil
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: format_error(reason))}
      end
    end
  end

  @impl true
  def handle_event("rejoin_as_player", %{"player_name" => name}, socket) do
    game_id = socket.assigns.game_name

    case Game.rejoin_game(game_id, name, self()) do
      {:ok, player_id, new_state} ->
        # Check if game already started
        if new_state.game_state != nil do
          {:noreply, push_navigate(socket, to: ~p"/#{game_id}?name=#{name}")}
        else
          {:noreply,
           socket
           |> assign(
             step: :lobby,
             player_id: player_id,
             player_name: name,
             server_state: new_state,
             selected_format: Map.get(new_state.format_selections, player_id),
             error: nil
           )
           |> push_patch(to: ~p"/?game=#{game_id}&name=#{name}")}
        end

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("select_format", %{"format" => format_str}, socket) do
    format = String.to_existing_atom(format_str)
    game_id = socket.assigns.game_name

    case Game.select_format(game_id, socket.assigns.player_id, format) do
      {:ok, new_state} ->
        {:noreply, assign(socket, server_state: new_state, selected_format: format, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("start_game", _params, socket) do
    game_id = socket.assigns.game_name
    player_name = socket.assigns.player_name
    dev_code = socket.assigns.dev_code

    # Parse dev codes into a list
    dev_codes =
      if dev_code != "" do
        dev_code
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
      else
        []
      end

    case Game.start_game_session(game_id, dev_codes) do
      {:ok, _new_state} ->
        # Navigate to game URL with player name for auto-rejoin
        {:noreply, push_navigate(socket, to: ~p"/#{game_id}?name=#{player_name}")}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("go_back", _params, socket) do
    {:noreply,
     socket
     |> assign(step: :game_name, error: nil)
     |> push_patch(to: ~p"/")}
  end

  @impl true
  def handle_event("update_dev_code", %{"dev_code" => dev_code}, socket) do
    # Parse and validate dev codes
    {valid_codes, invalid_codes} =
      if dev_code != "" do
        dev_code
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
        |> DevCodes.validate()
      else
        {[], []}
      end

    {:noreply,
     assign(socket,
       dev_code: dev_code,
       valid_dev_codes: valid_codes,
       invalid_dev_codes: invalid_codes
     )}
  end

  # Handle game state updates from PubSub
  @impl true
  def handle_info({:game_state_updated, new_state}, socket) do
    # Check if game started - navigate to game URL
    if new_state.game_state != nil do
      game_id = socket.assigns.game_name
      player_name = socket.assigns.player_name

      {:noreply, push_navigate(socket, to: ~p"/#{game_id}?name=#{player_name}")}
    else
      # Update disconnected players list
      disconnected_players =
        new_state.connections
        |> Enum.filter(fn {_id, conn} -> not conn.connected end)
        |> Enum.map(fn {id, conn} -> {id, conn.name} end)

      {:noreply,
       assign(socket,
         server_state: new_state,
         disconnected_players: disconnected_players
       )}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp format_error(:game_full), do: "Game is full"
  defp format_error(:name_taken), do: "Name already taken"
  defp format_error(:invalid_name), do: "Invalid name"
  defp format_error(reason) when is_atom(reason), do: "Error: #{reason}"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  # ============================================================================
  # RENDER
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <.brand_styles />
    <div class="min-h-screen-safe flex flex-col bg-gradient-to-br from-base-300 via-base-200 to-base-100 relative overflow-hidden">
      <.floating_battles />

      <div class="relative z-10 w-full flex flex-col flex-1 overflow-auto">
        <!-- Top spacer - pushes content down, logo stays at fixed distance from top -->
        <div class="shrink-0 h-[20vh] sm:h-[30vh]"></div>

        <div class="text-center px-6 max-w-xl w-full mx-auto">
          <!-- Logo section - stays at fixed position -->
          <div class="mb-8 animate-logo">
            <.logo_large />
            <p class="text-base-content/50 text-sm tracking-widest uppercase">
              Poker warfare
            </p>
          </div>
          
    <!-- Content section - grows below logo -->
          <div class="animate-content">
            <%= if @error do %>
              <div class="mb-4 text-red-500 text-sm font-medium bg-red-500/10 rounded-lg p-3">
                {@error}
              </div>
            <% end %>

            <%= case @step do %>
              <% :game_name -> %>
                <.game_name_form />
              <% :player_name -> %>
                <.player_name_form game_name={@game_name} inviter_name={@inviter_name} />
              <% :joining -> %>
                <.joining_screen
                  game_name={@game_name}
                  server_state={@server_state}
                  disconnected_players={@disconnected_players}
                />
              <% :lobby -> %>
                <.lobby_screen
                  game_name={@game_name}
                  player_id={@player_id}
                  player_name={@player_name}
                  server_state={@server_state}
                  selected_format={@selected_format}
                  dev_code={@dev_code}
                  valid_dev_codes={@valid_dev_codes}
                  invalid_dev_codes={@invalid_dev_codes}
                />
            <% end %>

            <%= if @step in [:game_name, :player_name] do %>
              <p class="text-base-content/40 text-xs mt-6">
                Play with friends · No signup required
              </p>
            <% end %>
          </div>
        </div>
        
    <!-- Bottom spacer - balances the layout -->
        <div class="flex-1"></div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # FORM COMPONENTS
  # ============================================================================

  defp game_name_form(assigns) do
    ~H"""
    <form phx-submit="new_game" class="space-y-3">
      <.brand_input name="player_name" placeholder="name" />
      <.brand_button type="submit" color={:primary}>
        New Game
      </.brand_button>
    </form>
    """
  end

  defp player_name_form(assigns) do
    ~H"""
    <%= if @inviter_name do %>
      <p class="text-base-content/60 text-sm mb-4 text-center">
        <span class="text-opponent font-semibold">{@inviter_name}</span> has challenged you
      </p>
    <% end %>

    <form phx-submit="submit_player_name" class="space-y-3">
      <.brand_input name="player_name" placeholder="name" />
      <.brand_button type="submit" color={:primary}>
        Join Game
      </.brand_button>
    </form>
    """
  end

  # ============================================================================
  # JOINING SCREEN (when game is full or reconnect options available)
  # ============================================================================

  defp joining_screen(assigns) do
    # Check if game is in progress or still in lobby
    game_in_progress = assigns.server_state && assigns.server_state.game_state != nil

    # Check if lobby can accept new players (less than 2 total connections)
    total_connections =
      if assigns.server_state, do: map_size(assigns.server_state.connections), else: 0

    can_join_as_new = not game_in_progress and total_connections < 2

    assigns =
      assigns
      |> assign(:game_in_progress, game_in_progress)
      |> assign(:can_join_as_new, can_join_as_new)

    ~H"""
    <div class="space-y-4">
      <div class="h-6 mb-2"></div>

      <%= if length(@disconnected_players) > 0 do %>
        <div class="space-y-3">
          <%= for {_player_id, player_name} <- @disconnected_players do %>
            <.brand_button
              phx-click="rejoin_as_player"
              phx-value-player_name={player_name}
              color={:yellow}
            >
              Reconnect as {player_name}
            </.brand_button>
          <% end %>
        </div>

        <%= if @can_join_as_new do %>
          <div class="flex items-center gap-4 my-4">
            <div class="flex-1 h-px bg-white/20"></div>
            <span class="text-base-content/40 text-sm">or</span>
            <div class="flex-1 h-px bg-white/20"></div>
          </div>

          <form phx-submit="submit_player_name" class="space-y-3">
            <.brand_input name="player_name" placeholder="Your name" />
            <.brand_button type="submit" color={:primary}>
              Join as New Player
            </.brand_button>
          </form>
        <% end %>
      <% else %>
        <p class="text-base-content/60 text-sm text-center">
          This game is full.
        </p>
      <% end %>

      <p class="text-base-content/40 text-xs mt-6 text-center">
        Game: {@game_name}
      </p>
    </div>
    """
  end

  # ============================================================================
  # LOBBY SCREEN
  # ============================================================================

  defp lobby_screen(assigns) do
    opponent_info =
      if assigns[:player_id] do
        opponent_id =
          assigns.server_state.connections
          |> Map.keys()
          |> Enum.find(&(&1 != assigns.player_id))

        if opponent_id do
          opponent_conn = assigns.server_state.connections[opponent_id]
          opponent_format = Map.get(assigns.server_state.format_selections, opponent_id)
          %{name: opponent_conn.name, format: opponent_format}
        end
      end

    assigns =
      assigns
      |> assign(:opponent_info, opponent_info)
      |> assign(:is_dev, @is_dev)

    ~H"""
    <div class="max-w-2xl mx-auto">
      <!-- Player Status Cards -->
      <.players_status_cards
        connections={@server_state.connections}
        player_id={@player_id}
        format_selections={@server_state.format_selections}
      />
      
    <!-- Format Selection -->
      <div class="mb-4 sm:mb-8">
        <p class="text-base-content/40 text-xs mb-2 sm:mb-3 text-center">
          <%= cond do %>
            <% map_size(@server_state.connections) < 2 -> %>
              Waiting for opponent to join...
            <% @selected_format == nil -> %>
              Choose a game mode
            <% !@opponent_info || @opponent_info.format == nil -> %>
              Waiting for opponent to select...
            <% @selected_format != @opponent_info.format -> %>
              Select the same game mode to start
            <% @selected_format == :short -> %>
              Both players selected Skirmish
            <% @selected_format == :standard -> %>
              Both players selected Battle
            <% @selected_format == :extended -> %>
              Both players selected War
            <% true -> %>
              Ready to start!
          <% end %>
        </p>
        <div class="grid grid-cols-3 gap-1.5 sm:gap-3">
          <.format_card_v2
            format="short"
            title="Skirmish"
            subtitle="~5 min match"
            description="Absolute chaos"
            emoji="⚡"
            lives={2}
            shop_rounds={1}
            selected={@selected_format == :short}
            opponent_selected={@opponent_info && @opponent_info.format == :short}
          />
          <.format_card_v2
            format="standard"
            title="Battle"
            subtitle="~15 min match"
            description="Balanced play"
            emoji="🎯"
            lives={3}
            shop_rounds={2}
            selected={@selected_format == :standard}
            opponent_selected={@opponent_info && @opponent_info.format == :standard}
          />
          <.format_card_v2
            format="extended"
            title="War"
            subtitle="~30 min match"
            description="Tactical precision"
            emoji="🔥"
            lives={5}
            shop_rounds={2}
            selected={@selected_format == :extended}
            opponent_selected={@opponent_info && @opponent_info.format == :extended}
          />
        </div>
      </div>
      
    <!-- Start Game Button -->
      <div class="text-center">
        <%= if @server_state.lobby_status == :ready_to_start do %>
          <.brand_button phx-click="start_game" color={:primary}>
            Start Game
          </.brand_button>
        <% else %>
          <button
            disabled
            class="relative w-full px-8 py-4 rounded-xl font-bold text-lg text-white/50 transition-all shadow-xl overflow-hidden cursor-not-allowed bg-gradient-to-r from-blue-600/50 to-blue-500/50"
          >
            <span class="relative z-10">Start Game</span>
            <.card_decorations />
          </button>
        <% end %>
        
    <!-- Invite link - secondary action -->
        <button
          type="button"
          phx-click={JS.dispatch("phx:share", to: "#share-link")}
          class="mt-3 inline-flex items-center gap-1.5 px-3 py-1.5 text-xs text-base-content/50 hover:text-base-content/70 transition-all"
        >
          <span id="share-link" class="hidden">{url(~p"/?game=#{@game_name}")}</span>
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8.684 13.342C8.886 12.938 9 12.482 9 12c0-.482-.114-.938-.316-1.342m0 2.684a3 3 0 110-2.684m0 2.684l6.632 3.316m-6.632-6l6.632-3.316m0 0a3 3 0 105.367-2.684 3 3 0 00-5.367 2.684zm0 9.316a3 3 0 105.368 2.684 3 3 0 00-5.368-2.684z"
            />
          </svg>
          <span>Invite friend</span>
        </button>
      </div>

      <%= if @is_dev do %>
        <!-- Dev Code Input (dev only) -->
        <div class="mt-8 pt-6 border-t border-base-content/10">
          <div class="text-xs text-base-content/40 uppercase tracking-widest mb-2">Dev Code</div>
          <form phx-change="update_dev_code">
            <input
              type="text"
              name="dev_code"
              value={@dev_code}
              placeholder="e.g. SHOP_FORCE_SCRAMBLER"
              autocomplete="off"
              class={[
                "w-full bg-white/50 backdrop-blur-sm border rounded-lg px-4 py-2 text-gray-700 placeholder-gray-400 focus:outline-none text-sm font-mono",
                cond do
                  length(@invalid_dev_codes) > 0 -> "border-red-400 focus:border-red-500"
                  length(@valid_dev_codes) > 0 -> "border-green-400 focus:border-green-500"
                  true -> "border-white/30 focus:border-white/60"
                end
              ]}
            />
          </form>
          <%= if length(@invalid_dev_codes) > 0 do %>
            <p class="text-[11px] text-red-500 mt-1 font-medium">
              Invalid: {Enum.join(@invalid_dev_codes, ", ")}
            </p>
          <% end %>
          <%= if length(@valid_dev_codes) > 0 do %>
            <p class="text-[11px] text-green-600 mt-1 font-medium">
              Active: {Enum.join(@valid_dev_codes, ", ")}
            </p>
          <% end %>
          <p class="text-[10px] text-base-content/30 mt-1">
            Valid codes: {Enum.join(DevCodes.all(), ", ")}
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp players_status_cards(assigns) do
    player_list = Map.to_list(assigns.connections)

    {player_conn, opponent_conn} =
      case player_list do
        [{id1, conn1}, {_id2, conn2}] ->
          if id1 == assigns.player_id, do: {conn1, conn2}, else: {conn2, conn1}

        [{id1, conn1}] ->
          if id1 == assigns.player_id, do: {conn1, nil}, else: {nil, conn1}

        [] ->
          {nil, nil}
      end

    assigns =
      assigns
      |> assign(:player_conn, player_conn)
      |> assign(:opponent_conn, opponent_conn)

    ~H"""
    <div class="flex items-center justify-center gap-2 sm:gap-4 mb-4 sm:mb-8">
      <span class="text-player font-bold text-lg sm:text-2xl">
        {(@player_conn && @player_conn.name) || "You"}
      </span>
      <span class="text-base-content/40 text-sm sm:text-lg">vs</span>
      <%= if @opponent_conn do %>
        <span class="text-opponent font-bold text-lg sm:text-2xl">{@opponent_conn.name}</span>
      <% else %>
        <span class="text-opponent font-bold text-lg sm:text-2xl">?</span>
      <% end %>
    </div>
    """
  end

  defp format_card_v2(assigns) do
    # Determine if both players selected this format for special animation
    both_selected = assigns.selected and assigns.opponent_selected

    assigns = assign(assigns, :both_selected, both_selected)

    ~H"""
    <div class={[
      "relative",
      @both_selected && "lock-in-wrapper"
    ]}>
      <button
        phx-click="select_format"
        phx-value-format={@format}
        class={[
          "relative w-full p-2.5 sm:p-5 rounded-xl sm:rounded-2xl transition-all border-2 text-center group",
          "bg-white/90 backdrop-blur-sm shadow-lg hover:shadow-xl hover:scale-105",
          "border-white/50 hover:border-white"
        ]}
      >
        <!-- Corner selection indicators -->
        <%= cond do %>
          <% @both_selected -> %>
            <!-- Both selected - animated lock-in corners -->
            <div class="absolute -top-[2px] -left-[2px] w-5 h-5 sm:w-6 sm:h-6 border-t-[3px] border-l-[3px] rounded-tl-xl sm:rounded-tl-2xl corner-lock-in-a">
            </div>
            <div class="absolute -top-[2px] -right-[2px] w-5 h-5 sm:w-6 sm:h-6 border-t-[3px] border-r-[3px] rounded-tr-xl sm:rounded-tr-2xl corner-lock-in-b">
            </div>
            <div class="absolute -bottom-[2px] -left-[2px] w-5 h-5 sm:w-6 sm:h-6 border-b-[3px] border-l-[3px] rounded-bl-xl sm:rounded-bl-2xl corner-lock-in-b">
            </div>
            <div class="absolute -bottom-[2px] -right-[2px] w-5 h-5 sm:w-6 sm:h-6 border-b-[3px] border-r-[3px] rounded-br-xl sm:rounded-br-2xl corner-lock-in-a">
            </div>
          <% @selected -> %>
            <!-- Only you selected - all player corners -->
            <div class="absolute -top-[2px] -left-[2px] w-4 h-4 sm:w-5 sm:h-5 border-t-[3px] border-l-[3px] border-player rounded-tl-xl sm:rounded-tl-2xl">
            </div>
            <div class="absolute -top-[2px] -right-[2px] w-4 h-4 sm:w-5 sm:h-5 border-t-[3px] border-r-[3px] border-player rounded-tr-xl sm:rounded-tr-2xl">
            </div>
            <div class="absolute -bottom-[2px] -left-[2px] w-4 h-4 sm:w-5 sm:h-5 border-b-[3px] border-l-[3px] border-player rounded-bl-xl sm:rounded-bl-2xl">
            </div>
            <div class="absolute -bottom-[2px] -right-[2px] w-4 h-4 sm:w-5 sm:h-5 border-b-[3px] border-r-[3px] border-player rounded-br-xl sm:rounded-br-2xl">
            </div>
          <% @opponent_selected -> %>
            <!-- Only opponent selected - all opponent corners -->
            <div class="absolute -top-[2px] -left-[2px] w-4 h-4 sm:w-5 sm:h-5 border-t-[3px] border-l-[3px] border-opponent rounded-tl-xl sm:rounded-tl-2xl">
            </div>
            <div class="absolute -top-[2px] -right-[2px] w-4 h-4 sm:w-5 sm:h-5 border-t-[3px] border-r-[3px] border-opponent rounded-tr-xl sm:rounded-tr-2xl">
            </div>
            <div class="absolute -bottom-[2px] -left-[2px] w-4 h-4 sm:w-5 sm:h-5 border-b-[3px] border-l-[3px] border-opponent rounded-bl-xl sm:rounded-bl-2xl">
            </div>
            <div class="absolute -bottom-[2px] -right-[2px] w-4 h-4 sm:w-5 sm:h-5 border-b-[3px] border-r-[3px] border-opponent rounded-br-xl sm:rounded-br-2xl">
            </div>
          <% true -> %>
            <!-- No selection -->
        <% end %>
        
    <!-- Abstract SVG decoration per format -->
        <div class="absolute inset-0 overflow-hidden text-gray-400 opacity-20">
          <%= case @format do %>
            <% "short" -> %>
              <!-- Bullet shapes flying right -->
              <svg
                class="absolute inset-0 w-full h-full"
                viewBox="0 0 100 100"
                preserveAspectRatio="none"
              >
                <path
                  d="M5 20 Q3 20 3 18 L3 16 Q3 14 5 14 L12 14 L16 17 L12 20 Z"
                  fill="currentColor"
                />
                <path
                  d="M70 35 Q68 35 68 33 L68 31 Q68 29 70 29 L77 29 L81 32 L77 35 Z"
                  fill="currentColor"
                />
                <path
                  d="M25 55 Q23 55 23 53 L23 51 Q23 49 25 49 L32 49 L36 52 L32 55 Z"
                  fill="currentColor"
                />
                <path
                  d="M80 75 Q78 75 78 73 L78 71 Q78 69 80 69 L87 69 L91 72 L87 75 Z"
                  fill="currentColor"
                />
                <path
                  d="M15 85 Q13 85 13 83 L13 81 Q13 79 15 79 L22 79 L26 82 L22 85 Z"
                  fill="currentColor"
                />
              </svg>
            <% "standard" -> %>
              <!-- Concentric circles -->
              <svg class="absolute -right-6 -bottom-6 w-28 h-28" viewBox="0 0 100 100">
                <circle cx="50" cy="50" r="45" fill="none" stroke="currentColor" stroke-width="2" />
                <circle cx="50" cy="50" r="32" fill="none" stroke="currentColor" stroke-width="2" />
                <circle cx="50" cy="50" r="19" fill="none" stroke="currentColor" stroke-width="2" />
                <circle cx="50" cy="50" r="6" fill="currentColor" />
              </svg>
            <% "extended" -> %>
              <!-- Train track going from bottom-left to top-right -->
              <svg class="absolute inset-0 w-full h-full" viewBox="0 0 100 100">
                <!-- Two parallel rails -->
                <line x1="5" y1="108" x2="115" y2="-2" stroke="currentColor" stroke-width="2.5" />
                <line x1="20" y1="120" x2="130" y2="10" stroke="currentColor" stroke-width="2.5" />
                <!-- Cross ties (chunky wooden sleepers) -->
                <line x1="9" y1="104" x2="24" y2="116" stroke="currentColor" stroke-width="4" />
                <line x1="21" y1="92" x2="36" y2="104" stroke="currentColor" stroke-width="4" />
                <line x1="33" y1="80" x2="48" y2="92" stroke="currentColor" stroke-width="4" />
                <line x1="45" y1="68" x2="60" y2="80" stroke="currentColor" stroke-width="4" />
                <line x1="57" y1="56" x2="72" y2="68" stroke="currentColor" stroke-width="4" />
                <line x1="69" y1="44" x2="84" y2="56" stroke="currentColor" stroke-width="4" />
                <line x1="81" y1="32" x2="96" y2="44" stroke="currentColor" stroke-width="4" />
                <line x1="93" y1="20" x2="108" y2="32" stroke="currentColor" stroke-width="4" />
                <line x1="105" y1="8" x2="120" y2="20" stroke="currentColor" stroke-width="4" />
              </svg>
          <% end %>
        </div>
        
    <!-- Text content - centered and stacked -->
        <div class="relative z-10 flex flex-col items-center gap-0.5 sm:gap-1">
          <div class="text-gray-800 font-bold text-sm sm:text-lg">{@title}</div>
          <div class="text-gray-500 text-[10px] sm:text-xs hidden sm:block">{@description}</div>
          <div class="text-gray-400 text-[10px] sm:text-xs">{@subtitle}</div>
        </div>
      </button>
    </div>
    """
  end

  # ============================================================================
  # BRAND COMPONENTS (inlined)
  # ============================================================================

  defp brand_styles(assigns) do
    ~H"""
    <style>
      @keyframes drift-right {
        0% { transform: translateX(-150px) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg)); }
        50% { transform: translateX(calc(100vw / 2 - 50px)) translateY(calc(var(--y-offset, 0px) + var(--y-wave, -15px))) rotate(calc(var(--rot, 0deg) + 3deg)); }
        100% { transform: translateX(calc(100vw + 150px)) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg)); }
      }
      @keyframes drift-left {
        0% { transform: translateX(calc(100vw + 150px)) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg)); }
        50% { transform: translateX(calc(100vw / 2 - 50px)) translateY(calc(var(--y-offset, 0px) + var(--y-wave, -15px))) rotate(calc(var(--rot, 0deg) - 3deg)); }
        100% { transform: translateX(-150px) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg)); }
      }
      .floating-battle {
        position: absolute;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 4px;
        opacity: 0.25;
        left: 0;
        top: var(--row, 10%);
      }
      .floating-battle.drift-r { animation: drift-right var(--speed, 20s) linear infinite; }
      .floating-battle.drift-l { animation: drift-left var(--speed, 20s) linear infinite; }
      .battle-hand { display: flex; gap: 2px; }
      .battle-hand.loser { opacity: 0.5; }
      .battle-vs {
        font-size: 9px;
        font-weight: bold;
        color: #fff;
        text-shadow: 0 1px 3px rgba(0,0,0,0.5);
        padding: 1px 6px;
        background: linear-gradient(135deg, #dc2626, #db2777);
        border-radius: 3px;
      }
      .mini-card {
        width: 24px;
        height: 34px;
        background: linear-gradient(145deg, #fff, #f0f0f0);
        border-radius: 3px;
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        font-weight: bold;
        font-size: 10px;
        line-height: 1;
      }
      .mini-card .rank { font-size: 9px; }
      .mini-card .suit { font-size: 8px; margin-top: -2px; }
      .mini-card.red { color: #dc2626; }
      .mini-card.black { color: #1f2937; }
      @keyframes pulse-glow {
        0%, 100% { box-shadow: 0 0 20px rgba(34, 197, 94, 0.3); }
        50% { box-shadow: 0 0 30px rgba(34, 197, 94, 0.6); }
      }
      .ready-glow { animation: pulse-glow 2s ease-in-out infinite; }
      @keyframes logo-slide-up {
        0% { transform: translateY(80px); }
        100% { transform: translateY(0); }
      }
      @keyframes content-fade-in {
        0% { opacity: 0; transform: translateY(20px); }
        100% { opacity: 1; transform: translateY(0); }
      }
      .animate-logo {
        animation: logo-slide-up 0.6s cubic-bezier(0.16, 1, 0.3, 1) forwards;
      }
      .animate-content {
        animation: content-fade-in 0.4s ease-out 0.3s forwards;
        opacity: 0;
      }
    </style>
    <script>
      window.addEventListener("phx:copy", (event) => {
        const text = event.target.innerText || event.target.textContent;
        navigator.clipboard.writeText(text).then(() => {
          // Brief visual feedback - change icon to checkmark
          const button = event.target.closest('button');
          const svg = button.querySelector('svg');
          const originalPath = svg.innerHTML;
          svg.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />';
          svg.classList.add('text-green-500');
          setTimeout(() => {
            svg.innerHTML = originalPath;
            svg.classList.remove('text-green-500');
          }, 1000);
        });
      });

      window.addEventListener("phx:share", (event) => {
        const text = event.target.innerText || event.target.textContent;

        // Check if Web Share API is supported
        if (navigator.share) {
          navigator.share({
            url: text
          }).catch((error) => {
            // User cancelled or error occurred - silently ignore
            console.log('Share cancelled or failed:', error);
          });
        } else {
          // Fallback to copy if Web Share API not supported
          navigator.clipboard.writeText(text).then(() => {
            const button = event.target.closest('button');
            const svg = button.querySelector('svg');
            const originalPath = svg.innerHTML;
            svg.innerHTML = '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />';
            svg.classList.add('text-green-500');
            setTimeout(() => {
              svg.innerHTML = originalPath;
              svg.classList.remove('text-green-500');
            }, 1000);
          });
        }
      });
    </script>
    """
  end

  defp logo_large(assigns) do
    ~H"""
    <div class="flex justify-center gap-2 mb-8">
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform -rotate-12 hover:rotate-0 transition-transform">
        <span class="text-gray-800">O</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform -rotate-6 hover:rotate-0 transition-transform">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">
          S
        </span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold hover:rotate-0 transition-transform">
        <span class="text-gray-800">K</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform rotate-6 hover:rotate-0 transition-transform">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">
          O
        </span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform rotate-12 hover:rotate-0 transition-transform">
        <span class="text-gray-800">L</span>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :placeholder, :string, default: ""

  defp brand_input(assigns) do
    ~H"""
    <input
      type="text"
      name={@name}
      placeholder={@placeholder}
      class="w-full bg-white/90 backdrop-blur-sm border-2 border-white/50 rounded-xl px-5 py-4 text-gray-800 placeholder-gray-400 focus:outline-none focus:border-white text-center text-lg transition-all shadow-lg"
      autocomplete="one-time-code"
      autocorrect="off"
      autocapitalize="off"
      spellcheck="false"
      data-1p-ignore="true"
      data-lpignore="true"
      data-form-type="other"
      data-google-autofill="off"
      phx-mounted={JS.focus()}
    />
    """
  end

  attr :type, :string, default: "button"
  attr :color, :atom, default: :primary
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  defp brand_button(assigns) do
    gradient =
      case assigns.color do
        :primary -> "from-blue-600 to-blue-500 hover:from-blue-700 hover:to-blue-600"
        :yellow -> "from-amber-500 to-yellow-500 hover:from-amber-600 hover:to-yellow-600"
        :green -> "from-green-600 to-emerald-600 hover:from-green-700 hover:to-emerald-700"
        # Legacy colors
        :red -> "from-red-600 to-pink-600 hover:from-red-700 hover:to-pink-700"
        :blue -> "from-blue-600 to-blue-500 hover:from-blue-700 hover:to-blue-600"
      end

    assigns = assign(assigns, :gradient, gradient)

    ~H"""
    <button
      type={@type}
      class={[
        "relative w-full px-8 py-4 rounded-xl font-bold text-lg text-white transition-all shadow-xl overflow-hidden",
        "hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98]",
        "bg-gradient-to-r #{@gradient}",
        @class
      ]}
      {@rest}
    >
      <span class="relative z-10">{render_slot(@inner_block)}</span>
      <.card_decorations />
    </button>
    """
  end

  defp card_decorations(assigns) do
    ~H"""
    <span
      class="absolute text-white/20 text-2xl"
      style="top: 8%; left: 8%; transform: rotate(-15deg);"
    >
      &#9824;
    </span>
    <span class="absolute text-white/20 text-xl" style="top: 60%; left: 5%; transform: rotate(10deg);">
      &#9830;
    </span>
    <span
      class="absolute text-white/20 text-3xl"
      style="top: 15%; right: 10%; transform: rotate(20deg);"
    >
      &#9829;
    </span>
    <span
      class="absolute text-white/20 text-xl"
      style="top: 55%; right: 8%; transform: rotate(-8deg);"
    >
      &#9827;
    </span>
    <span class="absolute text-white/20 text-lg" style="top: 35%; left: 20%; transform: rotate(5deg);">
      &#9829;
    </span>
    <span
      class="absolute text-white/20 text-2xl"
      style="top: 40%; right: 22%; transform: rotate(-12deg);"
    >
      &#9824;
    </span>
    """
  end

  defp mini_card(assigns) do
    color_class = if assigns.suit in [:hearts, :diamonds], do: "red", else: "black"

    suit_symbol =
      case assigns.suit do
        :hearts -> "&#9829;"
        :diamonds -> "&#9830;"
        :clubs -> "&#9827;"
        :spades -> "&#9824;"
      end

    assigns =
      assigns
      |> assign(:color_class, color_class)
      |> assign(:suit_symbol, suit_symbol)

    ~H"""
    <div class={"mini-card #{@color_class}"}>
      <span class="rank">{@rank}</span>
      <span class="suit">{raw(@suit_symbol)}</span>
    </div>
    """
  end

  defp floating_battles(assigns) do
    ~H"""
    <!-- Battle 1 -->
    <div
      class="floating-battle drift-r"
      style="--row: 6%; --speed: 28s; --rot: -2deg; --y-wave: -10px;"
    >
      <div class="battle-hand">
        <.mini_card rank="7" suit={:hearts} />
        <.mini_card rank="7" suit={:spades} />
        <.mini_card rank="7" suit={:diamonds} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="K" suit={:spades} />
        <.mini_card rank="K" suit={:hearts} />
      </div>
    </div>
    <!-- Battle 2 -->
    <div
      class="floating-battle drift-l"
      style="--row: 18%; --speed: 32s; --rot: 3deg; --y-wave: -12px; animation-delay: -8s;"
    >
      <div class="battle-hand">
        <.mini_card rank="3" suit={:clubs} />
        <.mini_card rank="3" suit={:diamonds} />
        <.mini_card rank="3" suit={:spades} />
        <.mini_card rank="9" suit={:hearts} />
        <.mini_card rank="9" suit={:clubs} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="5" suit={:hearts} />
        <.mini_card rank="6" suit={:spades} />
        <.mini_card rank="7" suit={:diamonds} />
        <.mini_card rank="8" suit={:clubs} />
        <.mini_card rank="9" suit={:hearts} />
      </div>
    </div>
    <!-- Battle 3 -->
    <div
      class="floating-battle drift-r"
      style="--row: 28%; --speed: 25s; --rot: -3deg; --y-wave: -8px; animation-delay: -14s;"
    >
      <div class="battle-hand">
        <.mini_card rank="A" suit={:spades} />
        <.mini_card rank="A" suit={:hearts} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="K" suit={:diamonds} />
        <.mini_card rank="K" suit={:clubs} />
      </div>
    </div>
    <!-- Battle 4 -->
    <div
      class="floating-battle drift-l"
      style="--row: 38%; --speed: 35s; --rot: 2deg; --y-wave: -14px; animation-delay: -5s;"
    >
      <div class="battle-hand">
        <.mini_card rank="J" suit={:spades} />
        <.mini_card rank="J" suit={:hearts} />
        <.mini_card rank="J" suit={:clubs} />
        <.mini_card rank="J" suit={:diamonds} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="2" suit={:hearts} />
        <.mini_card rank="6" suit={:hearts} />
        <.mini_card rank="9" suit={:hearts} />
        <.mini_card rank="J" suit={:hearts} />
        <.mini_card rank="K" suit={:hearts} />
      </div>
    </div>
    <!-- Battle 5 -->
    <div
      class="floating-battle drift-r"
      style="--row: 48%; --speed: 30s; --rot: -4deg; --y-wave: -10px; animation-delay: -20s;"
    >
      <div class="battle-hand loser">
        <.mini_card rank="A" suit={:hearts} />
        <.mini_card rank="A" suit={:spades} />
        <.mini_card rank="5" suit={:diamonds} />
        <.mini_card rank="5" suit={:clubs} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand">
        <.mini_card rank="Q" suit={:spades} />
        <.mini_card rank="Q" suit={:hearts} />
        <.mini_card rank="Q" suit={:clubs} />
      </div>
    </div>
    <!-- Battle 6 -->
    <div
      class="floating-battle drift-l"
      style="--row: 58%; --speed: 38s; --rot: 3deg; --y-wave: -12px; animation-delay: -12s;"
    >
      <div class="battle-hand">
        <.mini_card rank="4" suit={:clubs} />
        <.mini_card rank="5" suit={:clubs} />
        <.mini_card rank="6" suit={:clubs} />
        <.mini_card rank="7" suit={:clubs} />
        <.mini_card rank="8" suit={:clubs} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="9" suit={:hearts} />
        <.mini_card rank="9" suit={:spades} />
        <.mini_card rank="9" suit={:diamonds} />
        <.mini_card rank="9" suit={:clubs} />
      </div>
    </div>
    <!-- Battle 7 -->
    <div
      class="floating-battle drift-r"
      style="--row: 68%; --speed: 26s; --rot: -2deg; --y-wave: -9px; animation-delay: -25s;"
    >
      <div class="battle-hand">
        <.mini_card rank="5" suit={:spades} />
        <.mini_card rank="5" suit={:hearts} />
        <.mini_card rank="5" suit={:clubs} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="J" suit={:diamonds} />
        <.mini_card rank="J" suit={:clubs} />
      </div>
    </div>
    <!-- Battle 8 -->
    <div
      class="floating-battle drift-l"
      style="--row: 78%; --speed: 33s; --rot: 4deg; --y-wave: -11px; animation-delay: -18s;"
    >
      <div class="battle-hand loser">
        <.mini_card rank="10" suit={:spades} />
        <.mini_card rank="J" suit={:hearts} />
        <.mini_card rank="Q" suit={:clubs} />
        <.mini_card rank="K" suit={:diamonds} />
        <.mini_card rank="A" suit={:spades} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand">
        <.mini_card rank="K" suit={:clubs} />
        <.mini_card rank="K" suit={:diamonds} />
        <.mini_card rank="K" suit={:spades} />
        <.mini_card rank="4" suit={:hearts} />
        <.mini_card rank="4" suit={:spades} />
      </div>
    </div>
    <!-- Battle 9 -->
    <div
      class="floating-battle drift-r"
      style="--row: 88%; --speed: 29s; --rot: -3deg; --y-wave: -13px; animation-delay: -30s;"
    >
      <div class="battle-hand">
        <.mini_card rank="3" suit={:diamonds} />
        <.mini_card rank="7" suit={:diamonds} />
        <.mini_card rank="10" suit={:diamonds} />
        <.mini_card rank="Q" suit={:diamonds} />
        <.mini_card rank="A" suit={:diamonds} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="4" suit={:spades} />
        <.mini_card rank="5" suit={:hearts} />
        <.mini_card rank="6" suit={:clubs} />
        <.mini_card rank="7" suit={:diamonds} />
        <.mini_card rank="8" suit={:spades} />
      </div>
    </div>
    <!-- Battle 10 -->
    <div
      class="floating-battle drift-l"
      style="--row: 95%; --speed: 24s; --rot: 2deg; --y-wave: -8px; animation-delay: -7s;"
    >
      <div class="battle-hand">
        <.mini_card rank="8" suit={:diamonds} />
        <.mini_card rank="8" suit={:hearts} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="3" suit={:hearts} />
        <.mini_card rank="3" suit={:diamonds} />
      </div>
    </div>
    """
  end
end
