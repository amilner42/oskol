//// Per-viewer event filtering: the framework's guarantee that events never
//// name a token the viewer's scene does not show.

import gamekit/event.{Message, PhaseChanged, Revealed, TokenMoved}
import gamekit/scene
import gleam/option.{None, Some}

fn viewed() -> scene.Scene {
  scene.Scene(
    game: "t",
    phase: "p",
    viewer: scene.Player("p1"),
    players: [],
    zones: [
      scene.zone("public", scene.Row, [scene.token("a", "card")]),
      scene.hidden_zone("secret", None, scene.Stack, 3),
      scene.zone("empty", scene.Row, []),
    ],
    data: [],
  )
}

pub fn a_visible_token_keeps_its_id_test() {
  assert event.for_viewer([event.moved("a", "secret", "public")], viewed())
    == [event.moved("a", "secret", "public")]
}

pub fn a_token_the_viewer_cannot_see_loses_its_id_but_keeps_its_zones_test() {
  assert event.for_viewer([event.moved("b", "public", "secret")], viewed())
    == [TokenMoved("", Some("public"), Some("secret"))]
  assert event.for_viewer([event.moved("b", "secret", "secret")], viewed())
    == [TokenMoved("", Some("secret"), Some("secret"))]
  assert event.for_viewer([event.created("b", "secret")], viewed())
    == [TokenMoved("", None, Some("secret"))]
}

pub fn a_token_destroyed_out_of_a_visible_zone_keeps_its_id_test() {
  assert event.for_viewer([event.destroyed("z", "public")], viewed())
    == [event.destroyed("z", "public")]
  assert event.for_viewer([event.destroyed("z", "empty")], viewed())
    == [event.destroyed("z", "empty")]
  assert event.for_viewer([event.destroyed("z", "secret")], viewed())
    == [TokenMoved("", Some("secret"), None)]
}

pub fn reveals_the_viewer_cannot_see_are_dropped_test() {
  assert event.for_viewer(
      [Revealed("a", "public"), Revealed("q", "secret")],
      viewed(),
    )
    == [Revealed("a", "public")]
}

pub fn other_events_pass_through_in_order_test() {
  let events = [Message("hi"), PhaseChanged("shop"), event.moved("a", "x", "public")]
  assert event.for_viewer(events, viewed()) == events
}
