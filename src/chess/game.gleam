//// Chess: the gamekit contract entry.
////
//// The first seat is White. Chess needs no randomness, so the seeded rng is
//// accepted and unused. When a clock runs out the framework applies `Flag`
//// for the player: a win for the opponent, or a draw when the opponent
//// cannot possibly checkmate (FIDE 6.9 approximated by material).

import chess/board
import chess/engine.{type Action}
import chess/projection
import chess/state.{type GameState}
import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn game() -> Game(GameState, Action) {
  game.Game(
    info: info(),
    init: init,
    decode_action: decode_action,
    apply: engine.apply,
    legal: engine.legal,
    scene: projection.build,
    outcome: outcome,
    clocks: engine.on_the_clock,
    timeout: fn(_, _) { game.Act(engine.Flag) },
  )
}

pub fn info() -> game.Info {
  game.Info(
    slug: projection.slug,
    name: "Chess",
    tagline: "The immortal game",
    description: "The full FIDE game: castling, en passant, promotion, checkmate. Stalemate, threefold repetition, the fifty-move rule and dead positions are automatic draws.",
    min_players: 2,
    max_players: 2,
    formats: [
      game.format(
        "standard",
        "Standard",
        "One game, White moves first",
        dict.new(),
      ),
    ],
    clocks: ["none", "blitz", "rapid", "delay", "per_move"],
    default_clock: "none",
  )
}

pub fn init(
  _config: game.Config,
  seats: List(game.Seat),
  _rng: Rng,
) -> Result(GameState, String) {
  case seats {
    [_, _] -> Ok(state.new(list.map(seats, fn(seat) { #(seat.id, seat.name) })))
    _ -> Error("Chess needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  case incoming.name {
    "resign" -> Ok(engine.Resign)
    "move" -> {
      use from <- result.try(square_param(incoming.params, "from"))
      use to <- result.try(square_param(incoming.params, "to"))
      use promotion <- result.try(promo_param(incoming.params))
      Ok(engine.MovePiece(board.Move(from, to, promotion)))
    }
    other -> Error("Unknown action: " <> other)
  }
}

fn square_param(params, name: String) -> Result(Int, String) {
  use text <- result.try(action.string_param(params, name))
  board.parse_square(text)
  |> result.replace_error("Invalid square: " <> text)
}

fn promo_param(params) -> Result(option.Option(board.Kind), String) {
  case action.string_param(params, "promotion") {
    Error(_) -> Ok(None)
    Ok(id) ->
      engine.parse_promo(id)
      |> result.map(Some)
      |> result.replace_error("Invalid promotion: " <> id)
  }
}

pub fn outcome(state: GameState) -> game.Outcome {
  case state.phase {
    state.Playing -> game.Ongoing
    state.WonBy(color, _) -> game.Finished([state.player_of(state, color)])
    state.Drawn(_) -> game.Finished([])
  }
}
