//// A player's own sets on stub capabilities: making one and the sentences
//// that refuse it, putting a position in and taking it out (what reaches
//// the set's own ladder, and only that), and the privacy every door keeps:
//// somebody else's set is not found, in the same words as a set that is
//// not there at all.
////
//// Every cap a branch is not supposed to reach still panics, so "nothing
//// is written" is a test here too.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/decks.{
  type OwnDeck, Added, DeckCaps, IdTaken, Member, NameTaken, OwnDeck,
}
import oskol/caps/ids.{IdsCaps}
import oskol/caps/practice.{
  type PracticeCaps, Active, Cell, Day, Item, PracticeCaps, Summary, Suspended,
}
import oskol/caps/puzzles.{PuzzlesCaps, Stored}
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/error
import oskol/fakes
import oskol/handlers/decks as decks_handler
import oskol/handlers/own_decks as handler
import oskol/handlers/puzzles as puzzles_handler
import oskol/puzzles as pz

const set_id = "K7M2Q9XA"

const other_id = "Z3W8R1PB"

// ---------- What the stubs were asked to do ----------

@external(erlang, "erlang", "put")
fn put_log(key: String, value: List(String)) -> Dynamic

@external(erlang, "erlang", "get")
fn log_at(key: String) -> List(String)

fn reset() -> Nil {
  let _ = put_log("own_decks_log", [])
  Nil
}

fn note(line: String) -> Nil {
  let _ = put_log("own_decks_log", list.append(log_at("own_decks_log"), [line]))
  Nil
}

fn log() -> List(String) {
  log_at("own_decks_log")
}

// ---------- A world ----------

fn row(id: String, name: String) -> OwnDeck {
  OwnDeck(id: id, user_id: "u1", name: name, new_per_day: 5)
}

/// An account "u1" with these sets. Every set's ladder is empty and says
/// so; writing to one is recorded, by scope.
fn world(rows: List(OwnDeck)) -> Ctx {
  Ctx(
    ..fakes.ctx(),
    decks: DeckCaps(
      ..fakes.ctx().decks,
      own: fn(uid) {
        case uid {
          "u1" -> rows
          _ -> []
        }
      },
      size: fn(_) { 0 },
      members: fn(_) { [] },
      practice: fn(scope) { ladder(scope) },
    ),
  )
}

fn ladder(scope: String) -> PracticeCaps {
  PracticeCaps(
    ..fakes.ctx().practice,
    summary: fn(_, _) { [] },
    ladder: fn(_) { [0, 0, 0, 0, 0, 0, 0, 0] },
    day: fn(_) { Day(0, 5) },
    cells: fn(_) { [] },
    put_user: fn(uid, tz, per_day) {
      note(
        scope
        <> " put_user "
        <> uid
        <> " '"
        <> tz
        <> "' "
        <> string.inspect(per_day),
      )
      Ok(Nil)
    },
    put_items: fn(uid, items) {
      list.each(items, fn(item) {
        let Item(key, tags, content, position) = item
        note(
          scope
          <> " put_item "
          <> uid
          <> " "
          <> key
          <> " "
          <> string.inspect(tags)
          <> " "
          <> content
          <> " "
          <> string.inspect(position),
        )
      })
      // The first time it is new; after that it is already there.
      case list.contains(log(), "seen " <> scope) {
        True -> Ok(0)
        False -> {
          note("seen " <> scope)
          Ok(list.length(items))
        }
      }
    },
    resume: fn(uid, keys) {
      note(scope <> " resume " <> uid <> " " <> string.join(keys, ","))
      list.length(keys)
    },
    suspend: fn(uid, keys) {
      note(scope <> " suspend " <> uid <> " " <> string.join(keys, ","))
      list.length(keys)
    },
    place: fn(uid, positions) {
      list.each(positions, fn(pair: #(String, Int)) {
        note(
          scope
          <> " place "
          <> uid
          <> " "
          <> pair.0
          <> " "
          <> string.inspect(pair.1),
        )
      })
      list.length(positions)
    },
  )
}

fn me() {
  fakes.signed_in("g1", "u1")
}

fn stranger() {
  fakes.signed_in("g2", "u2")
}

fn creating(rows: List(OwnDeck), ids: List(String)) -> Ctx {
  let _ = put_log("own_decks_ids", ids)
  let ctx = world(rows)
  Ctx(
    ..ctx,
    ids: IdsCaps(..fakes.ctx().ids, deck_id: fn() {
      case log_at("own_decks_ids") {
        [id, ..rest] -> {
          let _ = put_log("own_decks_ids", rest)
          id
        }
        [] -> panic as "minted more ids than the test allowed"
      }
    }),
    decks: DeckCaps(..ctx.decks, create: fn(uid, id, name, per_day) {
      note("create " <> uid <> " " <> id <> " " <> name)
      assert per_day == 5
      case id {
        "TAKEN000" -> Error(IdTaken)
        _ ->
          case name {
            "Raced" -> Error(NameTaken)
            _ -> Ok(OwnDeck(id, uid, name, per_day))
          }
      }
    }),
  )
}

fn string_at(body: String, path: List(String)) -> String {
  let assert Ok(s) = json.parse(body, decode.at(path, decode.string))
  s
}

// ---------- Making one ----------

pub fn a_set_is_made_with_a_trimmed_name_and_a_minted_id_test() {
  reset()
  let assert Ok(body) =
    handler.create_json(creating([], [set_id]), me(), "  Back games  ")
  assert string_at(body, ["deck", "id"]) == set_id
  assert string_at(body, ["deck", "name"]) == "Back games"
  assert string.contains(body, "\"new_per_day\":5")
  assert string.contains(body, "\"size\":0")
  assert log() == ["create u1 " <> set_id <> " Back games"]
}

pub fn an_id_somebody_has_is_minted_again_test() {
  reset()
  let assert Ok(body) =
    handler.create_json(creating([], ["TAKEN000", set_id]), me(), "Primes")
  assert string_at(body, ["deck", "id"]) == set_id
}

pub fn making_a_set_is_refused_in_the_player_s_words_test() {
  reset()
  let never = creating([row(other_id, "Back Games")], [])
  // A guest is asked to sign in, and nothing is read.
  assert handler.create_json(fakes.ctx(), fakes.guest("g1"), "Mine")
    == Error(error.Conflict("sign_in", "Sign in to make a set of your own."))
  assert handler.create_json(never, me(), "   ")
    == Error(error.Invalid("name_missing", "Give it a name"))
  assert handler.create_json(never, me(), string.repeat("a", 41))
    == Error(error.Invalid("name_too_long", "40 characters at most"))
  let assert Error(error.Invalid("name_missing", _)) =
    handler.create_json(never, me(), "")
  // Counted after the trim.
  let assert Error(error.Invalid("name_taken", _)) =
    handler.create_json(never, me(), "  Back Games" <> string.repeat(" ", 40))
  // The same name in any case is taken.
  assert handler.create_json(never, me(), " back games")
    == Error(error.Invalid("name_taken", "You already have a set called that"))
  // So is one a racing request took first: the row's index says so.
  assert handler.create_json(creating([], [set_id]), me(), "Raced")
    == Error(error.Invalid("name_taken", "You already have a set called that"))
  // Fifty is the most.
  let fifty =
    list.range(1, 50)
    |> list.map(fn(n) {
      row("ID" <> string.inspect(n), "S" <> string.inspect(n))
    })
  assert handler.create_json(creating(fifty, []), me(), "One more")
    == Error(error.Invalid("too_many_sets", "That is a lot of sets"))
  // Nothing above wrote a row except the racing one, which the row refused.
  assert log() == ["create u1 " <> set_id <> " Raced"]
}

pub fn forty_characters_is_a_name_test() {
  reset()
  let assert Ok(_) =
    handler.create_json(creating([], [set_id]), me(), string.repeat("a", 40))
}

pub fn the_list_is_the_caller_s_and_a_guest_has_none_test() {
  let ctx = world([row(set_id, "Back games"), row(other_id, "Primes")])
  let body = handler.mine_json(ctx, me())
  let assert Ok(ids) =
    json.parse(
      body,
      decode.at(["decks"], decode.list(decode.at(["id"], decode.string))),
    )
  assert ids == [set_id, other_id]
  assert string.contains(body, "\"standing\":{")
  assert handler.mine_json(ctx, fakes.guest("g1"))
    == "{\"ok\":true,\"decks\":[]}"
  assert handler.mine_json(ctx, stranger()) == "{\"ok\":true,\"decks\":[]}"
}

// ---------- Renaming and deleting ----------

pub fn a_set_is_renamed_and_may_keep_its_own_name_in_another_case_test() {
  let rows = [row(set_id, "Back games"), row(other_id, "Primes")]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(..world(rows).decks, rename: fn(id, name) {
        Ok(OwnDeck(id, "u1", name, 5))
      }),
    )
  let assert Ok(body) = handler.rename_json(ctx, me(), set_id, "BACK GAMES")
  assert string_at(body, ["deck", "name"]) == "BACK GAMES"
  assert handler.rename_json(ctx, me(), set_id, "primes")
    == Error(error.Invalid("name_taken", "You already have a set called that"))
}

pub fn a_set_is_deleted_by_its_owner_only_test() {
  reset()
  let rows = [row(set_id, "Back games")]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(..world(rows).decks, delete: fn(id) {
        note("delete " <> id)
      }),
    )
  let missing = Error(error.NotFound("There is no such set of puzzles."))
  assert handler.delete_json(ctx, stranger(), set_id) == missing
  assert handler.delete_json(ctx, fakes.guest("g1"), set_id) == missing
  assert log() == []
  let assert Ok(_) = handler.delete_json(ctx, me(), set_id)
  assert log() == ["delete " <> set_id]
}

// ---------- Putting a position in, taking it out ----------

fn filling(rows: List(OwnDeck)) -> Ctx {
  let ctx = world(rows)
  Ctx(
    ..ctx,
    puzzles: PuzzlesCaps(..fakes.ctx().puzzles, get: fn(id) {
      case id {
        "p1" -> Some(Stored("p1", "double", "{\"kind\":\"double\"}", "{}"))
        _ -> None
      }
    }),
    decks: DeckCaps(
      ..ctx.decks,
      add_member: fn(deck, puzzle) {
        let added = !list.contains(log(), "member " <> deck <> " " <> puzzle)
        case added {
          True -> note("member " <> deck <> " " <> puzzle)
          False -> Nil
        }
        Added(added: added, position: 4)
      },
      remove_member: fn(deck, puzzle) {
        note("unmember " <> deck <> " " <> puzzle)
        True
      },
      // What add_member wrote, and remove_member has not taken away.
      members: fn(deck) {
        let saved = list.contains(log(), "member " <> deck <> " p1")
        let gone = list.contains(log(), "unmember " <> deck <> " p1")
        case saved && !gone {
          True -> [Member("p1", 4, "double", "{\"kind\":\"double\"}")]
          False -> []
        }
      },
    ),
  )
}

pub fn a_position_is_saved_onto_the_set_s_own_ladder_once_test() {
  reset()
  let ctx = filling([row(set_id, "Back games")])
  let assert Ok(first) = handler.add_json(ctx, me(), set_id, "p1")
  assert string.contains(first, "\"added\":true")
  assert string_at(first, ["deck", "id"]) == set_id
  let scope = "deck:" <> set_id
  // One membership row, and one item in the set's own scope -- at the end
  // of the set, with the set's tags and the question as its content --
  // after the owner's learner is made sure of at the set's pace.
  assert log()
    == [
      "member " <> set_id <> " p1",
      scope <> " put_user u1 '' 5",
      scope
        <> " put_item u1 p1 [#(\"deck\", \""
        <> set_id
        <> "\"), #(\"kind\", \"double\")] {\"kind\":\"double\"} Some(4)",
      "seen " <> scope,
    ]

  // The second time nothing is new: added is false, and the item that is
  // already there is left (and resumed, which a card in rotation ignores).
  reset()
  let _ = note("member " <> set_id <> " p1")
  let _ = note("seen " <> scope)
  let assert Ok(again) = handler.add_json(ctx, me(), set_id, "p1")
  assert string.contains(again, "\"added\":false")
  assert list.filter(log(), fn(l) { string.contains(l, "member ") })
    == ["member " <> set_id <> " p1"]
  // A card already on the ladder is resumed and goes to where its row is:
  // taken out once, saved again at the set's end.
  assert list.contains(log(), scope <> " resume u1 p1")
  assert list.contains(log(), scope <> " place u1 p1 4")
}

pub fn a_puzzle_that_is_not_there_is_not_saved_test() {
  reset()
  let ctx = filling([row(set_id, "Back games")])
  assert handler.add_json(ctx, me(), set_id, "nope")
    == Error(error.NotFound("No such puzzle"))
  assert log() == []
}

pub fn a_position_taken_out_is_put_away_not_forgotten_test() {
  reset()
  let ctx = filling([row(set_id, "Back games")])
  let _ = note("member " <> set_id <> " p1")
  let assert Ok(body) = handler.remove_json(ctx, me(), set_id, "p1")
  assert string_at(body, ["deck", "id"]) == set_id
  // The card first, then the row: a remove that fails between the two is
  // finished by the next one.
  assert log()
    == [
      "member " <> set_id <> " p1",
      "deck:" <> set_id <> " suspend u1 p1",
      "unmember " <> set_id <> " p1",
    ]
}

pub fn a_position_not_in_the_set_is_not_taken_out_test() {
  reset()
  // An empty set, never saved into: nothing to suspend, no row to delete
  // (both would panic), and the answer is the set as it is.
  let ctx =
    Ctx(
      ..world([row(set_id, "Back games")]),
      decks: DeckCaps(
        ..world([row(set_id, "Back games")]).decks,
        members: fn(_) { [] },
      ),
    )
  let assert Ok(body) = handler.remove_json(ctx, me(), set_id, "p9")
  assert string_at(body, ["deck", "id"]) == set_id
  assert log() == []
}

pub fn a_position_taken_out_counts_for_nothing_in_the_set_test() {
  // Two saved, one taken out (suspended): the set holds one, and it is
  // patched; the suspended card is neither in the total nor in the grid.
  let rows = [row(set_id, "Back games")]
  let cells = [
    Cell("p1", "", 0, 0, Suspended, Some(1)),
    Cell("p2", "", 7, 0, Active, Some(2)),
  ]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(
        ..world(rows).decks,
        size: fn(_) { 1 },
        members: fn(_) { [Member("p2", 2, "move", "{}")] },
        practice: fn(scope) {
          PracticeCaps(
            ..ladder(scope),
            summary: fn(_, _) { [Summary([], 2, 0, 1, 1, 0, 3.5)] },
            ladder: fn(_) { [1, 0, 0, 0, 0, 0, 0, 1] },
            cells: fn(_) { cells },
          )
        },
      ),
    )
  let body = handler.mine_json(ctx, me())
  assert string.contains(
    body,
    "\"standing\":{\"joined\":true,\"total\":1,\"in_progress\":0,\"patched\":1,",
  )
  let assert Ok(shown) = handler.show_json(ctx, me(), set_id)
  assert string.contains(shown, "\"members\":[{\"id\":\"p2\"")
}

// ---------- A set is private ----------

pub fn somebody_else_s_set_is_not_there_at_any_door_test() {
  reset()
  // The owner's world: a stranger asking about it reads only their own
  // (empty) list of sets, and every write still panics.
  let ctx = filling([row(set_id, "Back games")])
  let missing = Error(error.NotFound("There is no such set of puzzles."))
  assert handler.show_json(ctx, stranger(), set_id) == missing
  assert handler.add_json(ctx, stranger(), set_id, "p1") == missing
  assert handler.remove_json(ctx, stranger(), set_id, "p1") == missing
  assert handler.rename_json(ctx, stranger(), set_id, "Mine") == missing
  assert decks_handler.session_json(ctx, stranger(), set_id) == missing
  assert decks_handler.join_json(ctx, stranger(), set_id, "") == missing
  assert decks_handler.more_json(ctx, stranger(), set_id) == missing
  assert decks_handler.session_json(ctx, fakes.guest("g1"), set_id) == missing
  // An answer counted against it is turned away before the puzzle is read.
  let attempted = puzzles_handler.Attempted(moves: [], band: None, key: "k1")
  assert puzzles_handler.attempt_in_json(
      ctx,
      stranger(),
      "p1",
      attempted,
      "",
      0,
      set_id,
    )
    == missing
  assert puzzles_handler.outcome_in_json(
      ctx,
      stranger(),
      "p1",
      "k1",
      "pass",
      set_id,
    )
    == missing
  assert log() == []
}

pub fn the_owner_plays_the_set_in_its_own_scope_test() {
  reset()
  let ctx = filling([row(set_id, "Back games")])
  let assert Ok(body) = handler.show_json(ctx, me(), set_id)
  assert string.contains(body, "\"members\":[]")
  // An own set needs no adding: joining writes nothing and answers the
  // session, as reading it does.
  let assert Ok(session) = decks_handler.join_json(ctx, me(), set_id, "")
  assert string.contains(session, "\"own\":true")
  let assert Ok(_) = decks_handler.session_json(ctx, me(), set_id)
  assert log() == []
}

// ---------- The save sheet's list ----------

pub fn the_save_sheet_s_list_says_which_sets_hold_the_puzzle_test() {
  let rows = [row(set_id, "Back games"), row(other_id, "Primes")]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(..world(rows).decks, members: fn(deck) {
        case deck == set_id {
          True -> [Member("p1", 1, "move", "{}")]
          False -> []
        }
      }),
    )
  let body = handler.mine_holding_json(ctx, me(), "p1")
  let assert Ok(holds) =
    json.parse(
      body,
      decode.at(
        ["decks"],
        decode.list({
          use id <- decode.field("id", decode.string)
          use holds <- decode.field("holds", decode.bool)
          use name <- decode.field("name", decode.string)
          decode.success(#(id, holds, name))
        }),
      ),
    )
  assert holds == [#(set_id, True, "Back games"), #(other_id, False, "Primes")]
  assert handler.mine_holding_json(ctx, fakes.guest("g1"), "p1")
    == "{\"ok\":true,\"decks\":[]}"
}

pub fn a_member_carries_its_question_for_the_small_board_test() {
  // A row that does not read as a question is null rather than a 500.
  let rows = [row(set_id, "Back games")]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(..world(rows).decks, members: fn(_) {
        [Member("p2", 2, "move", "{}")]
      }),
    )
  let assert Ok(shown) = handler.show_json(ctx, me(), set_id)
  assert string.contains(shown, "\"question\":null")
}

pub fn a_member_s_question_is_the_one_its_page_shows_test() {
  let question =
    pz.Question(
      kind: pz.Move,
      board: list.repeat(0, 26),
      dice: Some(#(6, 4)),
      cube_value: 1,
      cube_owner: pz.Centered,
      away_mover: 0,
      away_opponent: 0,
      crawford: False,
      jacoby: False,
    )
  let rows = [row(set_id, "Back games")]
  let ctx =
    Ctx(
      ..world(rows),
      decks: DeckCaps(..world(rows).decks, members: fn(_) {
        [
          Member("p3", 1, "move", json.to_string(pz.question_json(question))),
        ]
      }),
    )
  let assert Ok(shown) = handler.show_json(ctx, me(), set_id)
  let assert Ok(dice) =
    json.parse(
      shown,
      decode.at(
        ["members"],
        decode.list(decode.at(["question", "dice"], decode.list(decode.int))),
      ),
    )
  assert dice == [[6, 4]]
}
