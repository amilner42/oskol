defmodule OskolWeb.LandingLive do
  use OskolWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       step: :game_name,
       game_name: "",
       player_name: "",
       error: nil
     )}
  end

  @impl true
  def handle_event("submit_game_name", %{"game_name" => game_name}, socket) do
    game_name = String.trim(game_name)

    if game_name == "" do
      {:noreply, assign(socket, error: "Please enter a game name")}
    else
      {:noreply, assign(socket, step: :player_name, game_name: game_name, error: nil)}
    end
  end

  @impl true
  def handle_event("submit_player_name", %{"player_name" => player_name}, socket) do
    player_name = String.trim(player_name)

    if player_name == "" do
      {:noreply, assign(socket, error: "Please enter your name")}
    else
      # Navigate to the game with name as query param
      {:noreply,
       push_navigate(socket,
         to:
           "/g/#{URI.encode_www_form(socket.assigns.game_name)}?name=#{URI.encode_www_form(player_name)}"
       )}
    end
  end

  @impl true
  def handle_event("go_back", _params, socket) do
    {:noreply, assign(socket, step: :game_name, error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      @keyframes drift-right {
        0% {
          transform: translateX(-150px) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg));
        }
        50% {
          transform: translateX(calc(100vw / 2 - 50px)) translateY(calc(var(--y-offset, 0px) + var(--y-wave, -15px))) rotate(calc(var(--rot, 0deg) + 3deg));
        }
        100% {
          transform: translateX(calc(100vw + 150px)) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg));
        }
      }

      @keyframes drift-left {
        0% {
          transform: translateX(calc(100vw + 150px)) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg));
        }
        50% {
          transform: translateX(calc(100vw / 2 - 50px)) translateY(calc(var(--y-offset, 0px) + var(--y-wave, -15px))) rotate(calc(var(--rot, 0deg) - 3deg));
        }
        100% {
          transform: translateX(-150px) translateY(var(--y-offset, 0px)) rotate(var(--rot, 0deg));
        }
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

      .battle-hand {
        display: flex;
        gap: 2px;
      }

      .battle-hand.loser {
        opacity: 0.5;
      }

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
    </style>

    <div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-base-300 via-base-200 to-base-100 relative overflow-hidden">
      <!-- Floating battles background -->
      <.floating_battles />

      <div class="text-center px-6 max-w-xl w-full relative z-10">
        <div class="mb-10">
          <!-- OSKOL spelled out on cards -->
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
        </div>

        <%= if @error do %>
          <div class="mb-4 text-red-500 text-sm font-medium">
            {@error}
          </div>
        <% end %>

        <div class="space-y-3">
          <%= if @step == :game_name do %>
            <.game_name_form />
          <% else %>
            <.player_name_form game_name={@game_name} />
          <% end %>
        </div>

        <p class="text-base-content/40 text-xs mt-6">
          Share the game name with a friend
        </p>
      </div>
    </div>
    """
  end

  defp game_name_form(assigns) do
    ~H"""
    <form phx-submit="submit_game_name" class="space-y-3">
      <div class="h-6 mb-2"></div>

      <input
        type="text"
        name="game_name"
        placeholder="Enter game name"
        class="w-full bg-white/90 backdrop-blur-sm border-2 border-white/50 rounded-xl px-5 py-4 text-gray-800 placeholder-gray-400 focus:outline-none focus:border-white text-center text-lg transition-all shadow-lg"
        autocomplete="off"
        autofocus
        phx-mounted={JS.focus()}
      />

      <button
        type="submit"
        class="relative w-full px-8 py-4 rounded-xl font-bold text-lg bg-gradient-to-r from-red-600 to-pink-600 hover:from-red-700 hover:to-pink-700 text-white transition-all shadow-xl hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98] overflow-hidden"
      >
        <span class="relative z-10">Play Now</span>
        <.card_decorations />
      </button>
    </form>
    """
  end

  defp player_name_form(assigns) do
    ~H"""
    <form phx-submit="submit_player_name" class="space-y-3">
      <div class="h-6 mb-2"></div>

      <input
        type="text"
        name="player_name"
        placeholder="Your name"
        class="w-full bg-white/90 backdrop-blur-sm border-2 border-white/50 rounded-xl px-5 py-4 text-gray-800 placeholder-gray-400 focus:outline-none focus:border-white text-center text-lg transition-all shadow-lg"
        autocomplete="off"
        autofocus
        phx-mounted={JS.focus()}
      />

      <button
        type="submit"
        class="relative w-full px-8 py-4 rounded-xl font-bold text-lg bg-gradient-to-r from-red-600 to-pink-600 hover:from-red-700 hover:to-pink-700 text-white transition-all shadow-xl hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98] overflow-hidden"
      >
        <span class="relative z-10">Join {@game_name}</span>
        <.card_decorations />
      </button>
    </form>
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

  defp floating_battles(assigns) do
    ~H"""
    <!-- Battle 1: Three 7s vs Pair of Kings -->
    <div
      class="floating-battle drift-r"
      style="--row: 6%; --speed: 28s; --rot: -2deg; --y-wave: -10px; animation-delay: 0s;"
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

    <!-- Battle 2: Full house vs Straight -->
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

    <!-- Battle 3: Pair of Aces vs Pair of Kings -->
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

    <!-- Battle 4: Four Jacks vs Flush -->
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

    <!-- Battle 5: Two pair vs Three of a kind -->
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

    <!-- Battle 6: Straight flush vs Four 9s -->
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

    <!-- Battle 7: Three 5s vs Pair of Jacks -->
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

    <!-- Battle 8: Full house vs Straight -->
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

    <!-- Battle 9: Flush vs Straight -->
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

    <!-- Battle 10: Pair of 8s vs Pair of 3s -->
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

  defp mini_card(assigns) do
    color_class = if assigns.suit in [:hearts, :diamonds], do: "red", else: "black"

    suit_symbol =
      case assigns.suit do
        :hearts -> "&#9829;"
        :diamonds -> "&#9830;"
        :clubs -> "&#9827;"
        :spades -> "&#9824;"
      end

    assigns = assign(assigns, color_class: color_class, suit_symbol: suit_symbol)

    ~H"""
    <div class={"mini-card #{@color_class}"}>
      <span class="rank">{@rank}</span>
      <span class="suit">{raw(@suit_symbol)}</span>
    </div>
    """
  end
end
