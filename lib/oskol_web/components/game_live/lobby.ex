defmodule OskolWeb.Components.GameLive.Lobby do
  @moduledoc """
  Lobby and join screen components for the game.
  Uses shared Brand components for consistent visual design.
  """
  use OskolWeb, :html

  alias OskolWeb.Components.Shared.Brand

  def error_banner(assigns) do
    ~H"""
    <Brand.brand_page battle_density={:full}>
      <div class="px-6">
        <div class="w-full max-w-md mx-auto">
          <div class="mb-10 animate-logo">
            <Brand.logo_large />
          </div>
          <div class="animate-content">
            <div class="bg-red-500/10 backdrop-blur-sm border-2 border-red-500/30 rounded-xl p-6 shadow-xl">
              <p class="text-red-500 text-center font-medium">{@error}</p>
            </div>
          </div>
        </div>
      </div>
    </Brand.brand_page>
    """
  end

  def join_screen(assigns) do
    ~H"""
    <Brand.brand_page battle_density={:full}>
      <div class="px-6">
        <div class="w-full max-w-md mx-auto">
          <div class="mb-10 animate-logo">
            <Brand.logo_large />
          </div>

          <div class="animate-content">
          <!-- Game Name Badge -->
          <div class="text-center mb-8">
            <div class="inline-block bg-white/20 backdrop-blur-sm rounded-full px-4 py-2">
              <span class="text-base-content/60 text-sm">Game:</span>
              <span class="text-base-content font-semibold ml-1">{@game_name}</span>
            </div>
          </div>

          <%= if @server_state.game_state != nil do %>
            <div class="text-center mb-6">
              <h2 class="text-2xl font-bold text-base-content mb-2">Game in Progress</h2>
            </div>
          <% end %>

          <!-- Disconnected Players -->
          <%= if length(@disconnected_players) > 0 do %>
            <div class="bg-white/10 backdrop-blur-sm border-2 border-white/20 rounded-xl p-5 mb-6 shadow-lg">
              <p class="text-base-content font-semibold text-center mb-3">Reconnect as Player</p>
              <div class="space-y-2">
                <%= for {_player_id, player_name} <- @disconnected_players do %>
                  <Brand.brand_button phx-click="rejoin_as_player" phx-value-player_name={player_name} color={:blue}>
                    Join as {player_name}
                  </Brand.brand_button>
                <% end %>
              </div>
            </div>

            <%= if @server_state.game_state == nil do %>
              <div class="flex items-center gap-4 my-6">
                <div class="flex-1 h-px bg-white/20"></div>
                <span class="text-base-content/40 text-sm">or join as new player</span>
                <div class="flex-1 h-px bg-white/20"></div>
              </div>
            <% end %>
          <% else %>
            <%= if @server_state.game_state != nil do %>
              <div class="bg-white/10 backdrop-blur-sm border-2 border-white/20 rounded-xl p-5 mb-6">
                <p class="text-base-content/70 text-sm text-center">
                  This game is full. You cannot join at this time.
                </p>
              </div>
            <% end %>
          <% end %>

          <!-- Join Form -->
          <%= if @server_state.game_state == nil do %>
            <form phx-submit="join_game" class="space-y-4 mb-8">
              <Brand.brand_input name="player_name" placeholder="Your name" autofocus={true} />
              <Brand.brand_button type="submit" color={:red}>
                Join Game
              </Brand.brand_button>
            </form>
          <% end %>

          <!-- Players in Lobby -->
          <%= if map_size(@server_state.connections) > 0 do %>
            <.players_display connections={@server_state.connections} />
          <% end %>
          </div>
        </div>
      </div>
    </Brand.brand_page>
    """
  end

  def lobby_screen(assigns) do
    opponent_format =
      if assigns[:player_id] do
        opponent_id =
          assigns.server_state.connections
          |> Map.keys()
          |> Enum.find(&(&1 != assigns.player_id))

        if opponent_id, do: Map.get(assigns.server_state.format_selections, opponent_id)
      end

    assigns = assign(assigns, :opponent_format, opponent_format)

    ~H"""
    <Brand.brand_page battle_density={:full}>
      <div class="px-6">
        <div class="w-full max-w-lg mx-auto">
          <div class="mb-10 animate-logo">
            <Brand.logo_large />
          </div>

          <div class="animate-content">
          <!-- Player Status Cards -->
          <.players_status_cards
            connections={@server_state.connections}
            player_id={@player_id}
            format_selections={@server_state.format_selections}
          />

          <!-- Format Selection -->
          <div class="mb-8">
            <h3 class="text-base-content/80 text-sm font-medium text-center mb-4">Choose Game Length</h3>
            <div class="grid grid-cols-2 gap-3">
              <.format_card_modern
                format="quick"
                title="Quick"
                lives={1}
                shop_rounds={0}
                selected={@selected_format == :quick}
                opponent_selected={@opponent_format == :quick}
              />
              <.format_card_modern
                format="short"
                title="Short"
                lives={2}
                shop_rounds={1}
                selected={@selected_format == :short}
                opponent_selected={@opponent_format == :short}
              />
              <.format_card_modern
                format="standard"
                title="Standard"
                lives={3}
                shop_rounds={2}
                selected={@selected_format == :standard}
                opponent_selected={@opponent_format == :standard}
              />
              <.format_card_modern
                format="extended"
                title="Extended"
                lives={5}
                shop_rounds={2}
                selected={@selected_format == :extended}
                opponent_selected={@opponent_format == :extended}
              />
            </div>
          </div>

          <!-- Start Game Button -->
          <div class="text-center">
            <%= if @server_state.lobby_status == :ready_to_start do %>
              <Brand.brand_button phx-click="start_game" color={:green} class="ready-glow">
                Start Game
              </Brand.brand_button>
            <% else %>
              <div class="bg-white/10 backdrop-blur-sm rounded-xl px-6 py-4">
                <p class="text-base-content/60 text-sm">
                  <%= if map_size(@server_state.connections) < 2 do %>
                    Waiting for another player to join...
                  <% else %>
                    Select the same format to start
                  <% end %>
                </p>
              </div>
            <% end %>
          </div>
          </div>
        </div>
      </div>
    </Brand.brand_page>
    """
  end

  defp format_card_modern(assigns) do
    ~H"""
    <button
      phx-click="select_format"
      phx-value-format={@format}
      class={[
        "relative p-4 rounded-xl transition-all border-2 text-left",
        "bg-white/80 backdrop-blur-sm shadow-lg hover:shadow-xl hover:scale-[1.02]",
        if(@selected,
          do: "border-red-500 ring-2 ring-red-500/30",
          else: "border-white/50 hover:border-white"
        ),
        if(@opponent_selected and not @selected,
          do: "ring-2 ring-green-500/50",
          else: ""
        )
      ]}
    >
      <%= if @selected do %>
        <div class="absolute top-2 right-2 w-5 h-5 bg-red-500 rounded-full flex items-center justify-center">
          <svg class="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
          </svg>
        </div>
      <% end %>

      <%= if @opponent_selected and not @selected do %>
        <div class="absolute top-2 right-2 w-5 h-5 bg-green-500 rounded-full flex items-center justify-center">
          <span class="text-white text-xs font-bold">2</span>
        </div>
      <% end %>

      <div class="text-gray-800 font-bold text-lg mb-1">{@title}</div>
      <div class="text-gray-500 text-xs">
        <span class="inline-flex items-center gap-1">
          <span>{@lives}</span>
          <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
            <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
          </svg>
        </span>
        <span class="mx-1">•</span>
        <span>{if @shop_rounds == 0, do: "No shop", else: "#{@shop_rounds} shop"}</span>
      </div>
    </button>
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

    player_format = Map.get(assigns.format_selections, assigns.player_id)

    opponent_id =
      player_list
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.find(&(&1 != assigns.player_id))

    opponent_format = if opponent_id, do: Map.get(assigns.format_selections, opponent_id)

    formats_match = player_format && opponent_format && player_format == opponent_format

    assigns =
      assigns
      |> assign(:player_conn, player_conn)
      |> assign(:opponent_conn, opponent_conn)
      |> assign(:formats_match, formats_match)

    ~H"""
    <div class="flex gap-4 mb-8 justify-center">
      <!-- You -->
      <div class={[
        "flex-1 max-w-[180px] bg-white/80 backdrop-blur-sm rounded-xl p-4 border-2 shadow-lg text-center",
        if(@formats_match, do: "border-green-500", else: "border-blue-500")
      ]}>
        <div class="w-10 h-10 bg-gradient-to-br from-blue-500 to-blue-600 rounded-full mx-auto mb-2 flex items-center justify-center text-white font-bold text-lg">
          {String.first(@player_conn && @player_conn.name || "?")}
        </div>
        <div class="text-gray-800 font-semibold text-sm truncate">
          {@player_conn && @player_conn.name || "You"}
        </div>
        <div class="text-green-500 text-xs mt-1 flex items-center justify-center gap-1">
          <div class="w-1.5 h-1.5 bg-green-500 rounded-full"></div>
          Ready
        </div>
      </div>

      <!-- VS -->
      <div class="flex items-center">
        <div class="bg-gradient-to-r from-red-600 to-pink-600 text-white text-xs font-bold px-3 py-1 rounded-full shadow-lg">
          VS
        </div>
      </div>

      <!-- Opponent -->
      <div class={[
        "flex-1 max-w-[180px] backdrop-blur-sm rounded-xl p-4 border-2 shadow-lg text-center",
        if(@opponent_conn,
          do: if(@formats_match, do: "bg-white/80 border-green-500", else: "bg-white/80 border-white/50"),
          else: "bg-white/40 border-dashed border-white/30"
        )
      ]}>
        <%= if @opponent_conn do %>
          <div class="w-10 h-10 bg-gradient-to-br from-red-500 to-pink-500 rounded-full mx-auto mb-2 flex items-center justify-center text-white font-bold text-lg">
            {String.first(@opponent_conn.name)}
          </div>
          <div class="text-gray-800 font-semibold text-sm truncate">{@opponent_conn.name}</div>
          <div class={[
            "text-xs mt-1 flex items-center justify-center gap-1",
            if(@opponent_conn.connected, do: "text-green-500", else: "text-gray-400")
          ]}>
            <div class={[
              "w-1.5 h-1.5 rounded-full",
              if(@opponent_conn.connected, do: "bg-green-500", else: "bg-gray-400")
            ]}></div>
            {if @opponent_conn.connected, do: "Ready", else: "Offline"}
          </div>
        <% else %>
          <div class="w-10 h-10 bg-gray-300/50 rounded-full mx-auto mb-2 flex items-center justify-center text-gray-400 text-lg">
            ?
          </div>
          <div class="text-gray-400 font-semibold text-sm">Waiting...</div>
          <div class="text-gray-400/60 text-xs mt-1">for opponent</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp players_display(assigns) do
    ~H"""
    <div class="bg-white/10 backdrop-blur-sm rounded-xl p-4 border border-white/20">
      <p class="text-base-content/60 text-xs text-center mb-3">Players in Lobby</p>
      <div class="flex justify-center gap-3">
        <%= for {_id, conn} <- @connections do %>
          <div class="flex items-center gap-2 bg-white/80 rounded-full px-3 py-1.5">
            <div class={[
              "w-2 h-2 rounded-full",
              if(conn.connected, do: "bg-green-500", else: "bg-gray-400")
            ]}></div>
            <span class="text-gray-800 text-sm font-medium">{conn.name}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Keep old components for backwards compatibility
  def player_list(assigns) do
    ~H"""
    <div class="mb-6">
      <ul class="space-y-2">
        <%= for {_id, conn} <- @connections do %>
          <li class="flex items-center gap-3 px-4 py-3 bg-base-200 rounded-lg">
            <div class={[
              "w-2.5 h-2.5 rounded-full",
              if(conn.connected, do: "bg-success", else: "bg-base-content/30")
            ]}>
            </div>
            <span class="text-base-content font-medium">{conn.name}</span>
            <%= if !conn.connected do %>
              <span class="ml-auto text-xs text-base-content/50">offline</span>
            <% end %>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  def format_card(assigns) do
    ~H"""
    <button
      phx-click="select_format"
      phx-value-format={@format}
      class={[
        "w-full p-4 rounded-lg transition-all border-2",
        if(@selected,
          do: "bg-primary border-primary text-primary-content shadow-lg",
          else:
            "bg-base-200 border-base-300 text-base-content hover:border-primary/50 hover:bg-base-300"
        ),
        if(@opponent_selected,
          do: "ring-2 ring-success ring-offset-2 ring-offset-base-100",
          else: ""
        )
      ]}
    >
      <div class="text-left">
        <div class="font-bold text-lg mb-1">{@title}</div>
        <div class={[
          "text-sm",
          if(@selected, do: "text-primary-content/80", else: "text-base-content/60")
        ]}>
          {format_description(@lives, @shop_rounds)}
        </div>
      </div>
    </button>
    """
  end

  defp format_description(lives, 0), do: "#{lives} life • No shop"
  defp format_description(lives, shop_rounds), do: "#{lives} lives • #{shop_rounds} shop rounds"
end
