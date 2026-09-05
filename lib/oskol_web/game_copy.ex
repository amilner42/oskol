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
    "poker" => %{
      title: "Play heads-up poker online with a friend",
      description:
        "Heads-up no-limit Texas hold'em for two, free, no accounts. Pick a cash game or a sit-and-go, send a link, and your friend is dealt in.",
      intro: "No-limit hold'em for two, from a link. Free, no accounts, plays on a phone.",
      rules: [
        "Each player gets two cards face down, then five community cards come out in three rounds: the flop, the turn and the river. You make the best five-card hand from any of the seven.",
        "Heads-up, the player with the dealer button posts the small blind and acts first before the flop, last after it. Betting is no-limit: a bet is at least the big blind, a raise at least the size of the last raise, and you can move all in at any time.",
        "In a cash game the blinds stay put and your stack carries from hand to hand; with auto top-up you sit down with a full buy-in every hand. In a sit-and-go you both start with 1,500 chips and the blinds rise every few hands until one player is out."
      ],
      faq: [
        {"Is it real money?", "No. Chips are just chips: nothing to buy, nothing to cash out."},
        {"Do we need accounts?",
         "No. Type a name, that's it. A game stays open for an hour after the last move, so a dropped connection just means opening the link again."},
        {"What happens if someone stops playing?",
         "The clock decides. When it runs out the game checks or folds for you and the hand goes on, so a slow opponent can't stall a sit-and-go forever."},
        {"Can I see my opponent's cards?",
         "Only at a showdown. The server never sends a card you're not entitled to see, so there's nothing to peek at."}
      ]
    },
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
        "Free two-player games with no accounts: heads-up poker, backgammon and more. Pick a game, share the invite link, and your friend is in within seconds."
    }
  end
end
