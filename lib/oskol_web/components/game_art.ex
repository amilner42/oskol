defmodule OskolWeb.GameArt do
  @moduledoc """
  Per-game presentation for the library: a notebook-palette accent and a
  small piece of pixel art drawn from a character grid. Presentation only;
  a game with no entry here gets a neutral accent and a generic sprite, so
  registering a game never requires touching this module.
  """
  use Phoenix.Component

  # Notebook palette: pen blue, red pen, highlighter, pencil, marker colours.
  @palette %{
    "W" => "#ffffff",
    "K" => "#23243a",
    "L" => "#3d3f5c",
    "R" => "#e3453b",
    "B" => "#2f5fd0",
    "Y" => "#ffd93d",
    "G" => "#62c370",
    "P" => "#f27ba1",
    "S" => "#6ec1ff",
    "T" => "#f1dcb3",
    "N" => "#b97a4f"
  }

  @accents %{
    "tilt" => "#e3453b",
    "backgammon" => "#2f5fd0"
  }

  @sprites %{
    "tilt" => ~w(
      ........................
      ..KKKKKKKKKK............
      ..KBWWWWWWWK............
      ..KWWWBWWWKKKKKKKKKKKK..
      ..KWWBBBWWKRWWWWWWWWWK..
      ..KWBBBBBWKWWWWWWWWWWK..
      ..KWBBBBBWKWWRRWWRRWWK..
      ..KWWBWBWWKWRRRRRRRRWK..
      ..KWWWBWWWKWRRRRRRRRWK..
      ..KWWWBWWWKWWRRRRRRWWK..
      ..KWWWWWWWKWWWRRRRWWWK..
      ..KWWWWWWWKWWWWRRWWWWK..
      ..KWWWWWWWKWWWWWWWWWWK..
      YYYKKKKKKKKWWWWWWWWWWK..
      YKY.......KWWWWWWWWWRK..
      YYY.......KKKKKKKKKKKK..
    ),
    "backgammon" => ~w(
      KKKKKKKKKKKKKKKKKKKKKKKK
      KWWTRRRTTTNKKNWWRTTTLLRK
      KWWTRRRTTTNKKNWWRTTTLLRK
      KWWNNRNNTNNKKNNRNNTNNRNK
      KWWNNRNNTNNKKNNRNNTNNRNK
      KNNNNNNNNNNKKNNNNNNNNNNK
      KNNNWWWWNNNKKNNNYYYYNNNK
      KNNNWKWWNNNKKNNNYKKYNNNK
      KNNNWWKWNNNKKNNNYKKYNNNK
      KNNNWWWWNNNKKNNNYYYYNNNK
      KNNNNNNNNNNKKNNNNNNNNNNK
      KNRNNTNLLNNKKNNTNNRNNTNK
      KNRNNTNLLNNKKNNTNNRNNTNK
      KRRRTTTLLRNKKNTTTWWRTTTK
      KRRRTTTLLRNKKNTTTWWRTTTK
      KKKKKKKKKKKKKKKKKKKKKKKK
    ),
    "default" => ~w(
      ........................
      ....KKKKKK..............
      ...KWWWWWWK.............
      ...KWKWWKWK...KKKKKK....
      ...KWWWWWWK..KSSSSSSK...
      ...KWWKKWWK..KSKSSKSK...
      ...KWWWWWWK..KSSSSSSK...
      ....KKKKKK...KSKSSKSK...
      .............KSSSSSSK...
      ..............KKKKKK....
      ........................
      ......YYYYYYYYYY........
      ......YKKKKKKKKY........
      ......YYYYYYYYYY........
      ........................
      ........................
    )
  }

  @doc "Accent colour for a game slug."
  def accent(slug), do: Map.get(@accents, slug, "#62c370")

  attr :slug, :string, required: true
  attr :class, :string, default: ""

  @doc "Pixel art for the game as crisp SVG rectangles."
  def art(assigns) do
    rows = Map.get(@sprites, assigns.slug, @sprites["default"])
    height = length(rows)
    width = rows |> List.first() |> String.length()

    pixels =
      for {row, y} <- Enum.with_index(rows),
          {char, x} <- Enum.with_index(String.graphemes(row)),
          char != ".",
          do: {x, y, Map.get(@palette, char, "#000")}

    assigns = assign(assigns, pixels: pixels, width: width, height: height)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class={@class}
      shape-rendering="crispEdges"
      aria-hidden="true"
    >
      <rect :for={{x, y, color} <- @pixels} x={x} y={y} width="1" height="1" fill={color} />
    </svg>
    """
  end
end
