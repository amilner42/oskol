defmodule OskolWeb.Components.GameLive.Lobby do
  @moduledoc """
  Lobby and join screen components for the game.
  """
  use OskolWeb, :html

  def error_banner(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-red-900 border border-red-700 rounded p-4 mb-4">
        {@error}
      </div>
    </div>
    """
  end

  def player_list(assigns) do
    ~H"""
    <div class="mt-6">
      <h3 class="text-lg font-bold mb-2">Players:</h3>
      <ul class="space-y-2">
        <%= for {_id, conn} <- @connections do %>
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
    """
  end

  def disconnected_notice(assigns) do
    ~H"""
    <div class="bg-purple-900 border border-purple-700 rounded p-4 mb-6">
      <p class="text-purple-200 font-bold">Reconnection Available</p>
      <p class="text-purple-100 text-sm mt-2">
        A player disconnected. Click below to reconnect as them.
      </p>
    </div>
    """
  end

  def rejoin_buttons(assigns) do
    ~H"""
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
    """
  end

  def join_form(assigns) do
    ~H"""
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
    """
  end

  def join_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-gray-800 rounded-lg p-6">
        <h2 class="text-2xl font-bold mb-4">
          {if @server_state.game_state != nil, do: "Game in Progress", else: "Join Game"}
        </h2>

        <%= if length(@disconnected_players) > 0 do %>
          <.disconnected_notice />
          <.rejoin_buttons disconnected_players={@disconnected_players} />
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
          <.join_form />
        <% end %>

        <%= if map_size(@server_state.connections) > 0 do %>
          <.player_list connections={@server_state.connections} />
        <% end %>
      </div>
    </div>
    """
  end

  def lobby_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-gray-800 rounded-lg p-6">
        <h2 class="text-2xl font-bold mb-4">Lobby</h2>
        <p class="mb-4">You are: <span class="text-blue-400">{@player_name}</span></p>

        <.player_list connections={@server_state.connections} />

        <div class="mt-6 mb-6">
          <h3 class="text-lg font-bold mb-3">Game Mode</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <button
              phx-click="select_lives"
              phx-value-lives="1"
              class={[
                "p-3 rounded border-2 transition-all",
                if(@selected_lives == 1,
                  do: "bg-red-600 border-red-400 shadow-lg",
                  else: "bg-gray-700 border-gray-600 hover:bg-gray-600"
                )
              ]}
            >
              <div class="font-bold text-sm">Death Match</div>
              <div class="text-xs text-gray-300">1 Life</div>
            </button>

            <button
              phx-click="select_lives"
              phx-value-lives="3"
              class={[
                "p-3 rounded border-2 transition-all",
                if(@selected_lives == 3,
                  do: "bg-blue-600 border-blue-400 shadow-lg",
                  else: "bg-gray-700 border-gray-600 hover:bg-gray-600"
                )
              ]}
            >
              <div class="font-bold text-sm">Standard</div>
              <div class="text-xs text-gray-300">3 Lives</div>
            </button>

            <button
              phx-click="select_lives"
              phx-value-lives="5"
              class={[
                "p-3 rounded border-2 transition-all",
                if(@selected_lives == 5,
                  do: "bg-purple-600 border-purple-400 shadow-lg",
                  else: "bg-gray-700 border-gray-600 hover:bg-gray-600"
                )
              ]}
            >
              <div class="font-bold text-sm">Strategy</div>
              <div class="text-xs text-gray-300">5 Lives</div>
            </button>

            <button
              phx-click="select_lives"
              phx-value-lives="7"
              class={[
                "p-3 rounded border-2 transition-all",
                if(@selected_lives == 7,
                  do: "bg-green-600 border-green-400 shadow-lg",
                  else: "bg-gray-700 border-gray-600 hover:bg-gray-600"
                )
              ]}
            >
              <div class="font-bold text-sm">Marathon</div>
              <div class="text-xs text-gray-300">7 Lives</div>
            </button>
          </div>
        </div>

        <div class="mt-6">
          <%= if @server_state.lobby_status == :ready_to_start do %>
            <button
              phx-click="start_game"
              class="bg-green-600 hover:bg-green-700 px-6 py-3 rounded font-bold text-lg w-full"
            >
              Start Game!
            </button>
          <% else %>
            <p class="text-yellow-400">Waiting for another player...</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
