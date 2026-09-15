defmodule OskolWeb.GameCopy do
  @moduledoc """
  Landing-page prose per game: the title and description search engines
  show, a one-line intro, the rules in brief, and a few questions.
  Presentation only; the games themselves live in Gleam and never read this.
  """

  @type copy :: %{
          title: String.t(),
          description: String.t(),
          intro: String.t(),
          rules: [String.t()],
          faq: [{String.t(), String.t()}]
        }

  @copy %{
    "backgammon" => %{
      title: "Play backgammon online with a friend",
      description:
        "Backgammon for two with the doubling cube, free, no accounts. A single game, a match to 3, 5 or 7, or unlimited play; send a link and roll.",
      intro:
        "The race game with the doubling cube, from a link. Free, no accounts, plays on a phone.",
      rules: [
        "Each player has fifteen checkers racing around the board in opposite directions. Roll two dice and move checkers by the numbers shown; doubles move four times. A single checker on a point is a blot and can be hit and sent to the bar, from where it must re-enter before anything else moves.",
        "Once all your checkers are in your home board you bear them off. The first player to bear off all fifteen wins; a gammon (the loser has borne off nothing) counts double and a backgammon (the loser still has a checker on the bar or in the winner's home board) triple.",
        "Before rolling, a player may offer the doubling cube. Take it and the game is worth twice as much and the cube is yours; drop it and you lose the current stake. In match play the Crawford rule turns the cube off for one game when a player is one point from winning; in unlimited play the Jacoby rule means gammons only count once the cube has been turned."
      ],
      faq: [
        {"Can I take a move back?",
         "Until you press play. Moves are staged privately on your side; your opponent sees the board move only when you commit the turn."},
        {"Do we need accounts?",
         "No. Type a name and roll. A game stays open for an hour after the last move."},
        {"Is the dice fair?",
         "Every game is dealt from a seeded random generator on the server, and the whole game can be replayed from that seed. Nothing is chosen client-side."},
        {"Can we play a match?",
         "Yes: to 3, 5 or 7 points with the Crawford rule, or unlimited play with the Jacoby rule."}
      ]
    }
  }

  @doc "Copy for a game, with a plain fallback built from its info."
  @spec for_game(map()) :: copy()
  def for_game(info) do
    Map.get(@copy, info["slug"]) ||
      %{
        title: "Play #{info["name"]} online with a friend",
        description: "#{info["name"]} for two, free, no accounts. Send a link and play.",
        intro: info["description"],
        rules: [info["description"]],
        faq: []
      }
  end

  @doc "The library's own title and description."
  def site do
    %{
      title: "Two-player games from a link",
      description:
        "Free backgammon for two with no accounts: a single game, a match or unlimited play with the doubling cube. Share the invite link and your friend is in within seconds."
    }
  end
end
