defmodule OskolWeb.GameArt do
  @moduledoc """
  Per-game presentation for the library: an accent colour and a small
  illustration. This is client-side flavour, not game logic; unknown games
  fall back to a neutral look, so registering a game never requires an entry
  here (it only makes the poster prettier).
  """
  use Phoenix.Component

  @accents %{
    "tilt" => "#f43f5e",
    "backgammon" => "#f59e0b"
  }

  @doc "Accent colour for a game slug."
  def accent(slug), do: Map.get(@accents, slug, "#38bdf8")

  attr :slug, :string, required: true
  attr :class, :string, default: ""

  @doc "An illustration for the game, sized by the container."
  def art(%{slug: "tilt"} = assigns) do
    ~H"""
    <svg viewBox="0 0 200 130" class={@class} aria-hidden="true">
      <defs>
        <linearGradient id="tilt-card" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#ffffff" />
          <stop offset="1" stop-color="#e8e8ee" />
        </linearGradient>
      </defs>
      <g transform="translate(100 120)">
        <g transform="rotate(-24) translate(-30 -90)">
          <rect width="60" height="84" rx="7" fill="url(#tilt-card)" stroke="#d4d4dc" />
          <text x="8" y="22" font-size="16" font-weight="700" fill="#1f2937">10</text>
          <text x="30" y="58" font-size="26" text-anchor="middle" fill="#1f2937">♠</text>
        </g>
        <g transform="rotate(-8) translate(-30 -96)">
          <rect width="60" height="84" rx="7" fill="url(#tilt-card)" stroke="#d4d4dc" />
          <text x="8" y="22" font-size="16" font-weight="700" fill="#dc2626">J</text>
          <text x="30" y="58" font-size="26" text-anchor="middle" fill="#dc2626">♥</text>
        </g>
        <g transform="rotate(8) translate(-30 -96)">
          <rect width="60" height="84" rx="7" fill="url(#tilt-card)" stroke="#d4d4dc" />
          <text x="8" y="22" font-size="16" font-weight="700" fill="#1f2937">Q</text>
          <text x="30" y="58" font-size="26" text-anchor="middle" fill="#1f2937">♣</text>
        </g>
        <g transform="rotate(24) translate(-30 -90)">
          <rect width="60" height="84" rx="7" fill="url(#tilt-card)" stroke="#d4d4dc" />
          <text x="8" y="22" font-size="16" font-weight="700" fill="#dc2626">K</text>
          <text x="30" y="58" font-size="26" text-anchor="middle" fill="#dc2626">♦</text>
        </g>
      </g>
      <g transform="translate(160 22)">
        <circle r="14" fill="#f43f5e" opacity="0.9" />
        <text y="5" font-size="12" font-weight="800" text-anchor="middle" fill="#fff">x3</text>
      </g>
    </svg>
    """
  end

  def art(%{slug: "backgammon"} = assigns) do
    ~H"""
    <svg viewBox="0 0 200 130" class={@class} aria-hidden="true">
      <rect x="10" y="10" width="180" height="110" rx="8" fill="#3b2a1e" />
      <rect x="16" y="16" width="80" height="98" rx="4" fill="#5a4030" />
      <rect x="104" y="16" width="80" height="98" rx="4" fill="#5a4030" />
      <%= for {x, i} <- Enum.with_index([20, 33, 46, 59, 72, 85]) do %>
        <polygon
          points={"#{x},16 #{x + 10},16 #{x + 5},60"}
          fill={if rem(i, 2) == 0, do: "#f5deb3", else: "#b45309"}
        />
        <polygon
          points={"#{x},114 #{x + 10},114 #{x + 5},70"}
          fill={if rem(i, 2) == 0, do: "#b45309", else: "#f5deb3"}
        />
        <polygon
          points={"#{x + 88},16 #{x + 98},16 #{x + 93},60"}
          fill={if rem(i, 2) == 0, do: "#f5deb3", else: "#b45309"}
        />
        <polygon
          points={"#{x + 88},114 #{x + 98},114 #{x + 93},70"}
          fill={if rem(i, 2) == 0, do: "#b45309", else: "#f5deb3"}
        />
      <% end %>
      <%= for {cx, cy} <- [{25, 108}, {25, 99}, {25, 90}, {51, 22}, {51, 31}, {113, 108}, {113, 99}, {178, 22}, {178, 31}] do %>
        <circle cx={cx} cy={cy} r="4.5" fill="#f8fafc" stroke="#cbd5e1" />
      <% end %>
      <%= for {cx, cy} <- [{38, 22}, {38, 31}, {38, 40}, {77, 108}, {77, 99}, {165, 108}, {165, 99}, {126, 22}, {126, 31}] do %>
        <circle cx={cx} cy={cy} r="4.5" fill="#1f2937" stroke="#0f172a" />
      <% end %>
      <g transform="translate(150 62)">
        <rect x="-11" y="-11" width="22" height="22" rx="5" fill="#fff" />
        <circle cx="-5" cy="-5" r="2" fill="#111" />
        <circle cx="5" cy="5" r="2" fill="#111" />
        <circle cx="5" cy="-5" r="2" fill="#111" />
        <circle cx="-5" cy="5" r="2" fill="#111" />
      </g>
      <g transform="translate(58 62)">
        <rect x="-11" y="-11" width="22" height="22" rx="5" fill="#f59e0b" />
        <text y="5" font-size="12" font-weight="800" text-anchor="middle" fill="#fff">64</text>
      </g>
    </svg>
    """
  end

  def art(assigns) do
    ~H"""
    <svg viewBox="0 0 200 130" class={@class} aria-hidden="true">
      <g transform="translate(70 70) rotate(-12)">
        <rect x="-26" y="-26" width="52" height="52" rx="10" fill="#fff" />
        <circle cx="-12" cy="-12" r="5" fill="#111" />
        <circle cx="12" cy="12" r="5" fill="#111" />
        <circle cx="0" cy="0" r="5" fill="#111" />
      </g>
      <g transform="translate(130 60) rotate(14)">
        <rect x="-26" y="-26" width="52" height="52" rx="10" fill="#38bdf8" />
        <circle cx="-12" cy="-12" r="5" fill="#fff" />
        <circle cx="12" cy="-12" r="5" fill="#fff" />
        <circle cx="-12" cy="12" r="5" fill="#fff" />
        <circle cx="12" cy="12" r="5" fill="#fff" />
      </g>
    </svg>
    """
  end
end
