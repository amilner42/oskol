defmodule OskolWeb.Components.GameLive.Lobby do
  @moduledoc """
  Lobby and join screen components for the game.
  """
  use OskolWeb, :html

  def error_banner(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <div class="bg-error/10 border border-error/30 rounded-lg p-4 mb-4">
          <p class="text-error text-sm">{@error}</p>
        </div>
      </div>
    </div>
    """
  end

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

  def disconnected_notice(assigns) do
    ~H"""
    <div class="bg-base-200 border border-base-300 rounded-lg p-4 mb-6">
      <p class="text-base-content font-semibold">Reconnection Available</p>
      <p class="text-base-content/70 text-sm mt-1">
        A player disconnected. Click below to reconnect as them.
      </p>
    </div>
    """
  end

  def rejoin_buttons(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="space-y-3">
        <%= for {_player_id, player_name} <- @disconnected_players do %>
          <button
            phx-click="rejoin_as_player"
            phx-value-player_name={player_name}
            class="w-full bg-primary hover:bg-primary/90 text-primary-content px-6 py-3 rounded-lg font-semibold transition-all shadow-lg hover:shadow-xl hover:scale-[1.02]"
          >
            Reconnect as {player_name}
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def join_form(assigns) do
    ~H"""
    <form phx-submit="join_game" class="space-y-3">
      <input
        type="text"
        name="player_name"
        placeholder="Enter your name"
        class="w-full bg-base-200 border border-base-300 rounded-lg px-4 py-3 text-base-content placeholder-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
        autocomplete="off"
        autofocus
      />
      <button
        type="submit"
        class="w-full bg-primary hover:bg-primary/90 text-primary-content px-6 py-3 rounded-lg font-semibold transition-all shadow-lg hover:shadow-xl hover:scale-[1.02]"
      >
        Join Game
      </button>
    </form>
    """
  end

  def join_screen(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <!-- Header -->
        <div class="text-center mb-8">
          <h1 class="text-3xl font-bold text-base-content mb-2">
            {if @server_state.game_state != nil, do: "Game in Progress", else: "Welcome"}
          </h1>
          <%= if @server_state.game_state == nil do %>
            <p class="text-base-content/60 text-sm">Enter your name to join the game</p>
          <% end %>
        </div>
        
    <!-- Disconnected Players -->
        <%= if length(@disconnected_players) > 0 do %>
          <.disconnected_notice />
          <.rejoin_buttons disconnected_players={@disconnected_players} />
          <%= if @server_state.game_state == nil do %>
            <div class="relative my-8">
              <div class="absolute inset-0 flex items-center">
                <div class="w-full border-t border-base-300"></div>
              </div>
              <div class="relative flex justify-center text-sm">
                <span class="px-4 bg-base-100 text-base-content/60">Or join as new player</span>
              </div>
            </div>
          <% end %>
        <% else %>
          <%= if @server_state.game_state != nil do %>
            <div class="bg-base-200 border border-base-300 rounded-lg p-4 mb-6">
              <p class="text-base-content/70 text-sm text-center">
                This game is full and all players are connected. You cannot join or spectate at this time.
              </p>
            </div>
          <% end %>
        <% end %>
        
    <!-- Join Form -->
        <%= if @server_state.game_state == nil do %>
          <div class="mb-8">
            <.join_form />
          </div>
        <% end %>
        
    <!-- Players List -->
        <%= if map_size(@server_state.connections) > 0 do %>
          <div class="mt-8">
            <h3 class="text-sm font-semibold text-base-content/80 mb-3">Players in Lobby</h3>
            <.player_list connections={@server_state.connections} />
          </div>
        <% end %>
      </div>
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
          else: "bg-base-200 border-base-300 text-base-content hover:border-primary/50 hover:bg-base-300"
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

  def lobby_screen(assigns) do
    # Get opponent's format selection if available
    opponent_format =
      if assigns[:player_id] do
        opponent_id =
          assigns.server_state.connections
          |> Map.keys()
          |> Enum.find(&(&1 != assigns.player_id))

        if opponent_id do
          Map.get(assigns.server_state.format_selections, opponent_id)
        else
          nil
        end
      else
        nil
      end

    assigns = assign(assigns, :opponent_format, opponent_format)

    ~H"""
    <div class="min-h-screen bg-base-100 flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <!-- Player Info -->
        <div class="text-center mb-8">
          <span class="text-base-content/60 text-sm">Playing as</span>
          <div class="text-2xl font-semibold text-base-content mt-1">{@player_name}</div>
        </div>

    <!-- Players List -->
        <.player_list connections={@server_state.connections} />

    <!-- Format Selection -->
        <div class="mb-8">
          <h3 class="text-base-content font-semibold mb-4 text-center">Select Game Format</h3>
          <div class="space-y-3">
            <.format_card
              format="bullet"
              title="Bullet"
              lives={1}
              shop_rounds={0}
              selected={@selected_format == :bullet}
              opponent_selected={@opponent_format == :bullet}
            />
            <.format_card
              format="blitz"
              title="Blitz"
              lives={2}
              shop_rounds={1}
              selected={@selected_format == :blitz}
              opponent_selected={@opponent_format == :blitz}
            />
            <.format_card
              format="rapid"
              title="Rapid"
              lives={3}
              shop_rounds={2}
              selected={@selected_format == :rapid}
              opponent_selected={@opponent_format == :rapid}
            />
            <.format_card
              format="classical"
              title="Classical"
              lives={5}
              shop_rounds={2}
              selected={@selected_format == :classical}
              opponent_selected={@opponent_format == :classical}
            />
          </div>

          <%= if @opponent_format != nil do %>
            <div class="mt-3 text-center text-sm text-base-content/60">
              <%= if @selected_format == @opponent_format do %>
                <span class="text-success font-semibold">Both players ready!</span>
              <% else %>
                <span>Opponent selected different format</span>
              <% end %>
            </div>
          <% end %>
        </div>

    <!-- Start Game Button -->
        <div>
          <%= if @server_state.lobby_status == :ready_to_start do %>
            <button
              phx-click="start_game"
              class="w-full bg-primary hover:bg-primary/90 text-primary-content px-6 py-4 rounded-lg font-semibold text-lg transition-all shadow-lg hover:shadow-xl hover:scale-[1.02]"
            >
              Start Game
            </button>
          <% else %>
            <div class="text-center py-4 text-base-content/60">
              <%= if map_size(@server_state.connections) < 2 do %>
                Waiting for another player...
              <% else %>
                Both players must select the same format
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
