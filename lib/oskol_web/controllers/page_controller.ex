defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  @pronunciations [
    "Oskahl",
    "Oskoal",
    "Awskol",
    "Oh-skull",
    "Ostrich",
    "Oss-coal",
    "Oscar the Grouch",
    "Oz-kohl",
    "Awesome-cool",
    "Ask-all"
  ]

  def home(conn, _params) do
    pronunciation = Enum.random(@pronunciations)
    game_id = Nanoid.generate()

    render(conn, :home, pronunciation: pronunciation, game_id: game_id)
  end
end
