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
end
