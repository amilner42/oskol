defmodule OskolWeb.Layouts do
  @moduledoc """
  The root document shell for the Elm application.
  """
  use OskolWeb, :html

  embed_templates "layouts/*"

  @doc """
  The `<title>` text, never blank. A page that forgets to set `:page_title`
  would otherwise render nothing but the `· Oskol` suffix.
  """
  def head_title(assigns), do: assigns[:page_title] || OskolWeb.GameCopy.site().title

  @doc """
  The card a link to this page unfurls as. A page with a picture of its
  own -- a puzzle's board, 1200 x 630, drawn once and served from
  `/puzzles/:id.png` -- sets `:puzzle_image` to that picture's absolute
  URL and gets the large card with it; every other page is the plain
  summary card, byte for byte what it was before there were pictures.
  """
  attr :image, :string, default: nil

  def share_card(%{image: nil} = assigns) do
    ~H"""
    <meta name="twitter:card" content="summary" />
    """
  end

  def share_card(assigns) do
    ~H"""
    <meta property="og:image" content={@image} />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:image" content={@image} />
    """
  end
end
