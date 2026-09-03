//// Golden replays. Every file under test/fixtures/replays is a seeded
//// playout with its final fingerprint; replaying the action log must land on
//// the same fingerprint. A rules change that alters any playout fails here.
//// When the change is intended, regenerate with `mix oskol.fixtures`.

import backgammon/game as backgammon
import gamekit/conformance.{type Step, Step}
import gamekit/game.{type Game, type Seat, Seat}
import gamekit/registry
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

@external(erlang, "oskol_test_files", "list")
fn list_dir(dir: String) -> Result(List(String), Dynamic)

@external(erlang, "oskol_test_files", "read")
fn read_file(path: String) -> Result(BitArray, Dynamic)

const dir = "test/fixtures/replays"

type Replay {
  Replay(
    game: String,
    format: String,
    seed: Int,
    seats: List(Seat),
    finished: Bool,
    steps: List(Step),
    fingerprint: String,
  )
}

fn replay_decoder() -> decode.Decoder(Replay) {
  let seat = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    decode.success(Seat(id, name))
  }
  let step = {
    use player_id <- decode.field("player_id", decode.string)
    use action <- decode.field("action", decode.string)
    decode.success(Step(player_id, action))
  }
  use game <- decode.field("game", decode.string)
  use format <- decode.field("format", decode.string)
  use seed <- decode.field("seed", decode.int)
  use seats <- decode.field("seats", decode.list(seat))
  use finished <- decode.field("finished", decode.bool)
  use steps <- decode.field("steps", decode.list(step))
  use fingerprint <- decode.field("fingerprint", decode.string)
  decode.success(Replay(
    game: game,
    format: format,
    seed: seed,
    seats: seats,
    finished: finished,
    steps: steps,
    fingerprint: fingerprint,
  ))
}

fn load() -> List(Replay) {
  let assert Ok(names) = list_dir(dir)
  names
  |> list.filter(string.ends_with(_, ".json"))
  |> list.map(fn(name) {
    let assert Ok(bytes) = read_file(dir <> "/" <> name)
    let assert Ok(text) = bit_array.to_string(bytes)
    let assert Ok(replay) = json.parse(text, replay_decoder())
    replay
  })
}

fn check(definition: Game(s, a), r: Replay) -> Nil {
  let assert Ok(final) =
    conformance.replay(definition, r.format, r.seats, r.seed, r.steps)
  let fingerprint = conformance.fingerprint(definition, final, r.seats)
  case fingerprint == r.fingerprint {
    True -> Nil
    False -> {
      let message =
        "Replay "
        <> r.game
        <> "/"
        <> r.format
        <> " seed "
        <> string.inspect(r.seed)
        <> " no longer reproduces its fingerprint. If the rules change was"
        <> " intended, run `mix oskol.fixtures`."
      panic as message
    }
  }
  let finished = case definition.outcome(final) {
    game.Finished(_) -> True
    game.Ongoing -> False
  }
  assert finished == r.finished
}

pub fn every_committed_replay_reproduces_its_fingerprint_test() {
  let replays = load()
  assert replays != []
  list.each(replays, fn(r) {
    case r.game {
      "backgammon" -> check(backgammon.game(), r)
      other ->
        panic as {
          "No typed game for replay " <> other <> ": add it to golden_test"
        }
    }
  })
}

pub fn every_registered_game_has_a_replay_for_every_format_test() {
  let replays = load()
  list.each(registry.all(), fn(entry) {
    list.each(entry.info.formats, fn(format) {
      let present =
        list.any(replays, fn(r) {
          r.game == entry.info.slug && r.format == format.id
        })
      case present {
        True -> Nil
        False ->
          panic as {
            "No replay fixture for "
            <> entry.info.slug
            <> "/"
            <> format.id
            <> ": run mix oskol.fixtures"
          }
      }
    })
  })
}
