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

  def lobby_screen(assigns) do
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

        <!-- Game Settings -->
        <div class="space-y-6 mb-8">
          <!-- Lives Selector -->
          <div class="flex items-center justify-between">
            <span class="text-base-content font-medium">Lives</span>
            <div class="flex gap-2">
              <button
                :for={lives <- [1, 3, 5, 7]}
                phx-click="select_lives"
                phx-value-lives={lives}
                class={[
                  "w-12 h-12 rounded-lg font-semibold transition-all",
                  if(@selected_lives == lives,
                    do: "bg-primary text-primary-content shadow-lg",
                    else: "bg-base-200 text-base-content/70 hover:bg-base-300"
                  )
                ]}
              >
                {lives}
              </button>
            </div>
          </div>

          <!-- Shop Rounds Selector -->
          <div class="flex items-center justify-between">
            <span class="text-base-content font-medium">Shop Rounds</span>
            <div class="flex gap-2">
              <button
                :for={rounds <- [0, 1, 2, 3]}
                phx-click="select_shop_rounds"
                phx-value-rounds={rounds}
                class={[
                  "w-12 h-12 rounded-lg font-semibold transition-all",
                  if(@selected_shop_rounds == rounds,
                    do: "bg-primary text-primary-content shadow-lg",
                    else: "bg-base-200 text-base-content/70 hover:bg-base-300"
                  )
                ]}
              >
                {rounds}
              </button>
            </div>
          </div>
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
              Waiting for another player...
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
