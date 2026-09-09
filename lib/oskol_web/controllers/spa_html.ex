defmodule OskolWeb.SpaHTML do
  @moduledoc """
  The shell the Elm app boots into. Everything a visitor sees is rendered by
  the client; the document head (in the root layout) is what the server has
  to say.
  """
  use OskolWeb, :html

  embed_templates "spa_html/*"
end
