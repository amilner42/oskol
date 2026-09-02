//// Hidden information in Tilt. Hands are open, but three things are secret:
//// the order of a draw pile, the face of a scrambled (face-down) card, and
//// a locked-in hand until both players have locked in. Scenes and events
//// must keep them secret for every viewer, throughout random games.

import gamekit/conformance
import gamekit/event
import gamekit/game.{Seat}
import gamekit/rng
import gamekit/scene
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/string
import tilt/codec
import tilt/engine
import tilt/game as tilt
import tilt/player.{type Player}
import tilt/poker/card
import tilt/state.{type GameState}

fn seats() {
  [Seat("p1", "Alice"), Seat("p2", "Bob")]
}

fn other(id: String) -> String {
  case id {
    "p1" -> "p2"
    _ -> "p1"
  }
}

fn viewer_name(viewer: scene.Viewer) -> String {
  case viewer {
    scene.Player(id) -> id
    scene.Spectator -> "a spectator"
  }
}

fn zone(sc: scene.Scene, id: String) -> scene.Zone {
  let assert Ok(z) = scene.find_zone(sc, id)
  z
}

fn by_face(a: card.Card, b: card.Card) -> order.Order {
  case int.compare(card.rank_value(a.rank), card.rank_value(b.rank)) {
    order.Eq ->
      string.compare(codec.suit_to_string(a.suit), codec.suit_to_string(b.suit))
    other -> other
  }
}

/// Every token of an open hand shows its face, except scrambled cards,
/// which show nothing to anyone.
fn hand_is_right(p: Player, hand: scene.Zone) -> Bool {
  list.length(hand.tokens) == list.length(p.card_piles.hand)
  && list.all(hand.tokens, fn(t) {
    case list.contains(p.face_down_card_ids, t.id) {
      True -> t.face == scene.Down && t.props == []
      False -> t.face == scene.Up && t.props != []
    }
  })
}

fn scenes_keep_secrets(s: GameState) -> Result(Nil, String) {
  let g = tilt.game()
  list.try_each(state.players_in_order(s), fn(p) {
    let me = p.player_id
    let locked = option.unwrap(p.locked_in_hand, [])
    use _ <- result.try(
      list.try_each([scene.Player(other(me)), scene.Spectator], fn(viewer) {
        let sc = g.scene(s, viewer)
        let deck = zone(sc, engine.deck_zone(me))
        let discard = zone(sc, engine.discard_zone(me))
        let played = zone(sc, engine.played_zone(me))
        let who = viewer_name(viewer) <> " sees " <> me <> "'s "
        case
          hand_is_right(p, zone(sc, engine.hand_zone(me))),
          deck.tokens,
          discard.tokens,
          played.tokens == [] || state.all_locked_in(s),
          played.count == list.length(locked)
        {
          True, [], [], True, True -> Ok(Nil)
          False, _, _, _, _ -> Error(who <> "hand wrongly")
          _, [_, ..], _, _, _ -> Error(who <> "draw pile")
          _, _, [_, ..], _, _ -> Error(who <> "discards")
          _, _, _, False, _ -> Error(who <> "locked-in hand early")
          _, _, _, _, False ->
            Error(who <> "played zone with the wrong count")
        }
      }),
    )
    // The holder sees what is left in their draw pile, sorted by face, so
    // the scene says nothing about the order they will draw in
    let own = g.scene(s, scene.Player(me))
    let deck = zone(own, engine.deck_zone(me))
    let sorted_by_face =
      list.map(deck.tokens, fn(t) { t.id })
      == list.map(list.sort(p.card_piles.deck, by_face), fn(c) { c.id })
    case
      hand_is_right(p, zone(own, engine.hand_zone(me))),
      list.length(deck.tokens) == list.length(p.card_piles.deck),
      sorted_by_face
    {
      True, True, True -> Ok(Nil)
      False, _, _ -> Error(me <> " sees their own hand wrongly")
      _, False, _ -> Error(me <> " sees the wrong draw pile")
      _, _, False -> Error(me <> " can see their own draw order")
    }
  })
}

/// Events never carry the face of a scrambled card.
fn events_keep_secrets(
  _before: GameState,
  actor: String,
  action_json: String,
  after: GameState,
  events: List(event.Event),
) -> Result(Nil, String) {
  let g = tilt.game()
  let face_down =
    list.flat_map(state.players_in_order(after), fn(p) {
      p.face_down_card_ids
    })
  list.try_each([scene.Player("p1"), scene.Player("p2"), scene.Spectator], fn(
    viewer,
  ) {
    let visible = event.for_viewer(events, g.scene(after, viewer))
    let text = json.to_string(json.array(visible, event.to_json))
    case
      list.find(face_down, fn(id) {
        string.contains(text, "\"id\":\"" <> id <> "\",\"rank\"")
      })
    {
      Ok(id) ->
        Error(
          "after "
          <> actor
          <> " "
          <> action_json
          <> ", "
          <> viewer_name(viewer)
          <> " learns the face of "
          <> id
          <> " from "
          <> text,
        )
      Error(_) -> Ok(Nil)
    }
  })
}

pub fn hidden_information_never_leaks_in_random_games_test() {
  list.each(list.range(1, 12), fn(seed) {
    let assert Ok(report) =
      conformance.random_playout_with(
        tilt.game(),
        "short",
        seats(),
        seed,
        3000,
        scenes_keep_secrets,
        conformance.Options(exclude: ["resign"]),
      )
    assert report.finished
    let assert Ok(_) =
      conformance.walk(
        tilt.game(),
        "short",
        seats(),
        seed,
        report.steps,
        events_keep_secrets,
      )
  })
}

pub fn card_ids_reveal_neither_face_nor_position_test() {
  let assert Ok(format) = game.find_format(tilt.info(), "short")
  let assert Ok(s) = tilt.init(format.config, seats(), rng.seed(4))
  list.each(state.players_in_order(s), fn(p) {
    let all = list.append(p.card_piles.hand, p.card_piles.deck)
    list.each(all, fn(c) { assert string.starts_with(c.id, p.player_id <> "-c") })
    // Labels are a shuffle of their own: the deck order is not the label order
    let labels = list.map(p.card_piles.deck, fn(c) { c.id })
    assert labels != list.sort(labels, string.compare)
    assert list.length(list.unique(labels)) == list.length(labels)
  })
}
