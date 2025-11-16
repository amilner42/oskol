defmodule OskolWeb.Components.GameLive.Lobby do
  @moduledoc """
  Lobby and join screen components for the game.
  """
  use OskolWeb, :html

  def error_banner(assigns) do
    ~H"""
    <div class="min-h-screen bg-white flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-4">
          <p class="text-red-800 text-sm">{@error}</p>
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
          <li class="flex items-center gap-3 px-4 py-3 bg-gray-50 rounded-lg">
            <div class={[
              "w-2.5 h-2.5 rounded-full",
              if(conn.connected, do: "bg-green-500", else: "bg-gray-400")
            ]}>
            </div>
            <span class="text-gray-900 font-medium">{conn.name}</span>
            <%= if !conn.connected do %>
              <span class="ml-auto text-xs text-gray-500">offline</span>
            <% end %>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  def disconnected_notice(assigns) do
    ~H"""
    <div class="bg-gray-50 border border-gray-200 rounded-lg p-4 mb-6">
      <p class="text-gray-900 font-semibold">Reconnection Available</p>
      <p class="text-gray-600 text-sm mt-1">
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
            class="w-full bg-gray-900 hover:bg-gray-800 text-white px-6 py-3 rounded-lg font-semibold transition-all shadow-sm hover:shadow-md"
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
        class="w-full bg-white border border-gray-300 rounded-lg px-4 py-3 text-gray-900 placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-gray-900 focus:border-transparent"
        autocomplete="off"
        autofocus
      />
      <button
        type="submit"
        class="w-full bg-gray-900 hover:bg-gray-800 text-white px-6 py-3 rounded-lg font-semibold transition-all shadow-sm hover:shadow-md"
      >
        Join Game
      </button>
    </form>
    """
  end

  def join_screen(assigns) do
    ~H"""
    <div class="min-h-screen bg-white flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <!-- Header -->
        <div class="text-center mb-8">
          <h1 class="text-3xl font-bold text-gray-900 mb-2">
            {if @server_state.game_state != nil, do: "Game in Progress", else: "Welcome"}
          </h1>
          <%= if @server_state.game_state == nil do %>
            <p class="text-gray-500 text-sm">Enter your name to join the game</p>
          <% end %>
        </div>

        <!-- Disconnected Players -->
        <%= if length(@disconnected_players) > 0 do %>
          <.disconnected_notice />
          <.rejoin_buttons disconnected_players={@disconnected_players} />
          <%= if @server_state.game_state == nil do %>
            <div class="relative my-8">
              <div class="absolute inset-0 flex items-center">
                <div class="w-full border-t border-gray-200"></div>
              </div>
              <div class="relative flex justify-center text-sm">
                <span class="px-4 bg-white text-gray-500">Or join as new player</span>
              </div>
            </div>
          <% end %>
        <% else %>
          <%= if @server_state.game_state != nil do %>
            <div class="bg-gray-50 border border-gray-200 rounded-lg p-4 mb-6">
              <p class="text-gray-600 text-sm text-center">
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
            <h3 class="text-sm font-semibold text-gray-700 mb-3">Players in Lobby</h3>
            <.player_list connections={@server_state.connections} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def lobby_screen(assigns) do
    ~H"""
    <div class="min-h-screen bg-white flex items-center justify-center p-6">
      <div class="w-full max-w-md">
        <!-- Player Info -->
        <div class="text-center mb-8">
          <span class="text-gray-500 text-sm">Playing as</span>
          <div class="text-2xl font-semibold text-gray-900 mt-1">{@player_name}</div>
        </div>

        <!-- Players List -->
        <.player_list connections={@server_state.connections} />

        <!-- Game Settings -->
        <div class="space-y-6 mb-8">
          <!-- Lives Selector -->
          <div class="flex items-center justify-between">
            <span class="text-gray-700 font-medium">Lives</span>
            <div class="flex gap-2">
              <button
                :for={lives <- [1, 3, 5, 7]}
                phx-click="select_lives"
                phx-value-lives={lives}
                class={[
                  "w-12 h-12 rounded-lg font-semibold transition-all",
                  if(@selected_lives == lives,
                    do: "bg-gray-900 text-white shadow-md",
                    else: "bg-gray-100 text-gray-600 hover:bg-gray-200"
                  )
                ]}
              >
                {lives}
              </button>
            </div>
          </div>

          <!-- Shop Rounds Selector -->
          <div class="flex items-center justify-between">
            <span class="text-gray-700 font-medium">Shop Rounds</span>
            <div class="flex gap-2">
              <button
                :for={rounds <- [0, 1, 2, 3]}
                phx-click="select_shop_rounds"
                phx-value-rounds={rounds}
                class={[
                  "w-12 h-12 rounded-lg font-semibold transition-all",
                  if(@selected_shop_rounds == rounds,
                    do: "bg-gray-900 text-white shadow-md",
                    else: "bg-gray-100 text-gray-600 hover:bg-gray-200"
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
              class="w-full bg-gray-900 hover:bg-gray-800 text-white px-6 py-4 rounded-lg font-semibold text-lg transition-all shadow-md hover:shadow-lg"
            >
              Start Game
            </button>
          <% else %>
            <div class="text-center py-4 text-gray-500">
              Waiting for another player...
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
