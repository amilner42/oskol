//// Poker: the gamekit contract entry. Heads-up No-Limit Texas Hold'em as
//// a cash game (pick the stakes, chips carry over, optional auto top-up)
//// or a sit-and-go (rising blinds until one player has every chip).

import gamekit/action
import gamekit/game.{type Game}
import gamekit/rng.{type Rng}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import poker/engine.{type Action}
import poker/projection
import poker/state.{type GameState}

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
    timeout: engine.timeout,
  )
}

/// Sit-and-go blind schedule, as (small, big).
pub const levels = [
  #(10, 20),
  #(15, 30),
  #(25, 50),
  #(50, 100),
  #(75, 150),
  #(100, 200),
  #(150, 300),
  #(200, 400),
  #(300, 600),
  #(400, 800),
  #(600, 1200),
  #(1000, 2000),
  #(1500, 3000),
  #(2000, 4000),
  #(3000, 6000),
  #(5000, 10_000),
]

pub const starting_stack = 1500

pub fn info() -> game.Info {
  game.Info(
    slug: projection.slug,
    name: "Poker",
    tagline: "Heads-up no-limit hold'em",
    description: "Texas hold'em for two. Sit down at a cash table with the stakes of your choice, or play a sit-and-go where the blinds climb until one of you has every chip.",
    min_players: 2,
    max_players: 2,
    formats: [
      game.Format(
        id: "cash",
        name: "Cash game",
        description: "Fixed blinds, chips carry over, leave when you like",
        config: dict.from_list([#("format", 0), #("top_up", 1)]),
        settings: [
          game.Setting(
            id: "stake",
            name: "Stakes",
            choices: [
              stake("1-2", "1 / 2", 1, 2),
              stake("2-5", "2 / 5", 2, 5),
              stake("5-10", "5 / 10", 5, 10),
              stake("10-20", "10 / 20", 10, 20),
              stake("25-50", "25 / 50", 25, 50),
              stake("50-100", "50 / 100", 50, 100),
            ],
            default: "1-2",
          ),
          game.Setting(
            id: "top_up",
            name: "Auto top-up",
            choices: [
              game.Choice(
                "yes",
                "Top up to the buy-in",
                dict.from_list([#("top_up", 1)]),
              ),
              game.Choice(
                "no",
                "Play what you have",
                dict.from_list([#("top_up", 0)]),
              ),
            ],
            default: "yes",
          ),
        ],
      ),
      game.Format(
        id: "sng",
        name: "Sit & go",
        description: "1,500 chips each, blinds rise, last chip wins",
        config: dict.from_list([
          #("format", 1),
          #("buy_in", starting_stack),
          #("hands_per_level", 10),
        ]),
        settings: [
          game.Setting(
            id: "speed",
            name: "Speed",
            choices: [
              game.Choice(
                "regular",
                "Regular",
                dict.from_list([#("hands_per_level", 10)]),
              ),
              game.Choice(
                "turbo",
                "Turbo",
                dict.from_list([#("hands_per_level", 6)]),
              ),
              game.Choice(
                "hyper",
                "Hyper",
                dict.from_list([#("hands_per_level", 3)]),
              ),
            ],
            default: "regular",
          ),
        ],
      ),
    ],
    clocks: ["poker", "poker_fast", "poker_slow", "none"],
    default_clock: "poker",
  )
}

/// A cash stake: blinds and a 100 big blind buy-in.
fn stake(id: String, name: String, small: Int, big: Int) -> game.Choice {
  game.Choice(
    id,
    name,
    dict.from_list([#("small", small), #("big", big), #("buy_in", big * 100)]),
  )
}

pub fn init(
  config: game.Config,
  seats: List(game.Seat),
  rng: Rng,
) -> Result(GameState, String) {
  case list.length(seats) {
    2 -> {
      let cash = game.config_get(config, "format", 0) == 0
      let poker_config = case cash {
        True ->
          state.Config(
            format: state.Cash,
            buy_in: game.config_get(config, "buy_in", 200),
            top_up: game.config_get(config, "top_up", 1) == 1,
            levels: [
              #(
                game.config_get(config, "small", 1),
                game.config_get(config, "big", 2),
              ),
            ],
            hands_per_level: 0,
          )
        False ->
          state.Config(
            format: state.SitAndGo,
            buy_in: game.config_get(config, "buy_in", starting_stack),
            top_up: False,
            levels: levels,
            hands_per_level: game.config_get(config, "hands_per_level", 10),
          )
      }
      let #(started, _) =
        state.new(poker_config, list.map(seats, fn(s) { #(s.id, s.name) }), rng)
      Ok(started)
    }
    _ -> Error("Poker needs exactly two players")
  }
}

pub fn decode_action(incoming: action.Incoming) -> Result(Action, String) {
  case incoming.name {
    "fold" -> Ok(engine.Fold)
    "check" -> Ok(engine.Check)
    "call" -> Ok(engine.Call)
    "all_in" -> Ok(engine.AllIn)
    "deal" -> Ok(engine.Deal)
    "resign" -> Ok(engine.Resign)
    "bet" -> {
      use amount <- result.try(action.int_param(incoming.params, "amount"))
      Ok(engine.Bet(amount))
    }
    "raise" -> {
      use amount <- result.try(action.int_param(incoming.params, "amount"))
      Ok(engine.Raise(amount))
    }
    other -> Error("Unknown action: " <> other)
  }
}

pub fn outcome(state: GameState) -> game.Outcome {
  case state.phase {
    state.Finished(Some(id)) -> game.Finished([id])
    state.Finished(None) -> game.Finished([])
    _ -> game.Ongoing
  }
}
