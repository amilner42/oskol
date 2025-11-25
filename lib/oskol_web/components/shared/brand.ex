defmodule OskolWeb.Components.Shared.Brand do
  @moduledoc """
  Shared brand components and styles for consistent visual design
  across landing page, lobby, and other screens.
  """
  use OskolWeb, :html

  @doc """
  Renders the shared CSS styles for floating battles and mini cards.
  Include this once at the top of any page using brand components.
  """
  def brand_styles(assigns) do
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
        opacity: var(--battle-opacity, 0.25);
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
        width: var(--card-width, 24px);
        height: var(--card-height, 34px);
        background: linear-gradient(145deg, #fff, #f0f0f0);
        border-radius: 3px;
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        font-weight: bold;
        font-size: var(--card-font, 10px);
        line-height: 1;
      }
      .mini-card .rank { font-size: calc(var(--card-font, 10px) * 0.9); }
      .mini-card .suit { font-size: calc(var(--card-font, 10px) * 0.8); margin-top: -2px; }
      .mini-card.red { color: #dc2626; }
      .mini-card.black { color: #1f2937; }
      .mini-card.small { --card-width: 20px; --card-height: 28px; --card-font: 8px; }
      @keyframes pulse-glow {
        0%, 100% { box-shadow: 0 0 20px rgba(34, 197, 94, 0.3); }
        50% { box-shadow: 0 0 30px rgba(34, 197, 94, 0.6); }
      }
      .ready-glow { animation: pulse-glow 2s ease-in-out infinite; }

      /* Page entrance animations */
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
    """
  end

  @doc """
  Full page wrapper with gradient background and floating battles.
  """
  attr :battle_opacity, :string, default: "0.25"
  attr :battle_density, :atom, default: :full, values: [:full, :sparse]
  slot :inner_block, required: true

  def brand_page(assigns) do
    ~H"""
    <.brand_styles />
    <div
      class="min-h-screen flex items-center justify-center bg-gradient-to-br from-base-300 via-base-200 to-base-100 relative overflow-hidden"
      style={"--battle-opacity: #{@battle_opacity}"}
    >
      <%= if @battle_density == :full do %>
        <.floating_battles />
      <% else %>
        <.floating_battles_sparse />
      <% end %>
      <div class="relative z-10 w-full">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Large OSKOL logo with card-style letters (for landing page).
  """
  def logo_large(assigns) do
    ~H"""
    <div class="flex justify-center gap-2 mb-8">
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform -rotate-12 hover:rotate-0 transition-transform">
        <span class="text-gray-800">O</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform -rotate-6 hover:rotate-0 transition-transform">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">S</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold hover:rotate-0 transition-transform">
        <span class="text-gray-800">K</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform rotate-6 hover:rotate-0 transition-transform">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">O</span>
      </div>
      <div class="w-16 h-22 sm:w-20 sm:h-28 bg-white rounded-xl shadow-2xl flex items-center justify-center text-4xl sm:text-5xl font-bold transform rotate-12 hover:rotate-0 transition-transform">
        <span class="text-gray-800">L</span>
      </div>
    </div>
    """
  end

  @doc """
  Small OSKOL logo with card-style letters (for lobby/game screens).
  """
  def logo_small(assigns) do
    ~H"""
    <div class="flex justify-center gap-1 mb-6">
      <div class="w-8 h-11 bg-white rounded-lg shadow-lg flex items-center justify-center text-lg font-bold transform -rotate-6">
        <span class="text-gray-800">O</span>
      </div>
      <div class="w-8 h-11 bg-white rounded-lg shadow-lg flex items-center justify-center text-lg font-bold transform -rotate-3">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">S</span>
      </div>
      <div class="w-8 h-11 bg-white rounded-lg shadow-lg flex items-center justify-center text-lg font-bold">
        <span class="text-gray-800">K</span>
      </div>
      <div class="w-8 h-11 bg-white rounded-lg shadow-lg flex items-center justify-center text-lg font-bold transform rotate-3">
        <span class="bg-gradient-to-br from-red-600 to-pink-600 bg-clip-text text-transparent">O</span>
      </div>
      <div class="w-8 h-11 bg-white rounded-lg shadow-lg flex items-center justify-center text-lg font-bold transform rotate-6">
        <span class="text-gray-800">L</span>
      </div>
    </div>
    """
  end

  @doc """
  Card suit decorations for buttons (spades, hearts, diamonds, clubs).
  """
  def card_decorations(assigns) do
    ~H"""
    <span class="absolute text-white/20 text-2xl" style="top: 8%; left: 8%; transform: rotate(-15deg);">&#9824;</span>
    <span class="absolute text-white/20 text-xl" style="top: 60%; left: 5%; transform: rotate(10deg);">&#9830;</span>
    <span class="absolute text-white/20 text-3xl" style="top: 15%; right: 10%; transform: rotate(20deg);">&#9829;</span>
    <span class="absolute text-white/20 text-xl" style="top: 55%; right: 8%; transform: rotate(-8deg);">&#9827;</span>
    <span class="absolute text-white/20 text-lg" style="top: 35%; left: 20%; transform: rotate(5deg);">&#9829;</span>
    <span class="absolute text-white/20 text-2xl" style="top: 40%; right: 22%; transform: rotate(-12deg);">&#9824;</span>
    """
  end

  @doc """
  Primary action button with gradient and card decorations.
  """
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :color, :atom, default: :red, values: [:red, :green, :blue]
  attr :rest, :global
  slot :inner_block, required: true

  def brand_button(assigns) do
    gradient =
      case assigns.color do
        :red -> "from-red-600 to-pink-600 hover:from-red-700 hover:to-pink-700"
        :green -> "from-green-600 to-emerald-600 hover:from-green-700 hover:to-emerald-700"
        :blue -> "from-blue-600 to-blue-500 hover:from-blue-700 hover:to-blue-600"
      end

    assigns = assign(assigns, :gradient, gradient)

    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "relative w-full px-8 py-4 rounded-xl font-bold text-lg text-white transition-all shadow-xl overflow-hidden",
        "hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98]",
        "disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:scale-100",
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

  @doc """
  Styled text input matching the brand aesthetic.
  """
  attr :name, :string, required: true
  attr :placeholder, :string, default: ""
  attr :value, :string, default: ""
  attr :autofocus, :boolean, default: false
  attr :rest, :global

  def brand_input(assigns) do
    ~H"""
    <input
      type="text"
      name={@name}
      value={@value}
      placeholder={@placeholder}
      autofocus={@autofocus}
      class="w-full bg-white/90 backdrop-blur-sm border-2 border-white/50 rounded-xl px-5 py-4 text-gray-800 placeholder-gray-400 focus:outline-none focus:border-white text-center text-lg transition-all shadow-lg"
      autocomplete="off"
      {@rest}
    />
    """
  end

  @doc """
  Mini playing card for floating battles.
  """
  attr :rank, :string, required: true
  attr :suit, :atom, required: true, values: [:hearts, :diamonds, :clubs, :spades]
  attr :size, :atom, default: :normal, values: [:normal, :small]

  def mini_card(assigns) do
    color_class = if assigns.suit in [:hearts, :diamonds], do: "red", else: "black"
    size_class = if assigns.size == :small, do: "small", else: ""

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
      |> assign(:size_class, size_class)
      |> assign(:suit_symbol, suit_symbol)

    ~H"""
    <div class={"mini-card #{@color_class} #{@size_class}"}>
      <span class="rank">{@rank}</span>
      <span class="suit"><%= raw(@suit_symbol) %></span>
    </div>
    """
  end

  @doc """
  Full set of floating battles (10 battles, for landing page).
  """
  def floating_battles(assigns) do
    ~H"""
    <!-- Battle 1: Three 7s vs Pair of Kings -->
    <div class="floating-battle drift-r" style="--row: 6%; --speed: 28s; --rot: -2deg; --y-wave: -10px; animation-delay: 0s;">
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
    <div class="floating-battle drift-l" style="--row: 18%; --speed: 32s; --rot: 3deg; --y-wave: -12px; animation-delay: -8s;">
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
    <div class="floating-battle drift-r" style="--row: 28%; --speed: 25s; --rot: -3deg; --y-wave: -8px; animation-delay: -14s;">
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
    <div class="floating-battle drift-l" style="--row: 38%; --speed: 35s; --rot: 2deg; --y-wave: -14px; animation-delay: -5s;">
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
    <div class="floating-battle drift-r" style="--row: 48%; --speed: 30s; --rot: -4deg; --y-wave: -10px; animation-delay: -20s;">
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
    <div class="floating-battle drift-l" style="--row: 58%; --speed: 38s; --rot: 3deg; --y-wave: -12px; animation-delay: -12s;">
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
    <div class="floating-battle drift-r" style="--row: 68%; --speed: 26s; --rot: -2deg; --y-wave: -9px; animation-delay: -25s;">
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
    <div class="floating-battle drift-l" style="--row: 78%; --speed: 33s; --rot: 4deg; --y-wave: -11px; animation-delay: -18s;">
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
    <div class="floating-battle drift-r" style="--row: 88%; --speed: 29s; --rot: -3deg; --y-wave: -13px; animation-delay: -30s;">
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
    <div class="floating-battle drift-l" style="--row: 95%; --speed: 24s; --rot: 2deg; --y-wave: -8px; animation-delay: -7s;">
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

  @doc """
  Sparse floating battles (3 battles, for lobby/game screens).
  """
  def floating_battles_sparse(assigns) do
    ~H"""
    <!-- Battle 1 -->
    <div class="floating-battle drift-r" style="--row: 15%; --speed: 35s; --rot: -2deg; --y-wave: -10px; animation-delay: 0s;">
      <div class="battle-hand">
        <.mini_card rank="A" suit={:spades} size={:small} />
        <.mini_card rank="A" suit={:hearts} size={:small} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="K" suit={:diamonds} size={:small} />
        <.mini_card rank="K" suit={:clubs} size={:small} />
      </div>
    </div>

    <!-- Battle 2 -->
    <div class="floating-battle drift-l" style="--row: 45%; --speed: 40s; --rot: 3deg; --y-wave: -12px; animation-delay: -15s;">
      <div class="battle-hand">
        <.mini_card rank="J" suit={:spades} size={:small} />
        <.mini_card rank="J" suit={:hearts} size={:small} />
        <.mini_card rank="J" suit={:clubs} size={:small} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="10" suit={:hearts} size={:small} />
        <.mini_card rank="10" suit={:spades} size={:small} />
      </div>
    </div>

    <!-- Battle 3 -->
    <div class="floating-battle drift-r" style="--row: 75%; --speed: 38s; --rot: -3deg; --y-wave: -8px; animation-delay: -8s;">
      <div class="battle-hand">
        <.mini_card rank="Q" suit={:hearts} size={:small} />
        <.mini_card rank="Q" suit={:diamonds} size={:small} />
        <.mini_card rank="Q" suit={:clubs} size={:small} />
        <.mini_card rank="Q" suit={:spades} size={:small} />
      </div>
      <div class="battle-vs">VS</div>
      <div class="battle-hand loser">
        <.mini_card rank="5" suit={:clubs} size={:small} />
        <.mini_card rank="6" suit={:clubs} size={:small} />
        <.mini_card rank="7" suit={:clubs} size={:small} />
        <.mini_card rank="8" suit={:clubs} size={:small} />
        <.mini_card rank="9" suit={:clubs} size={:small} />
      </div>
    </div>
    """
  end
end
