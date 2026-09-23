//// The JSON the Elm client reads. The shapes are asserted here, on the
//// real registry (games are pure Gleam) and stub capabilities.

import gamekit/clock
import gamekit/game as gk_game
import gamekit/instance.{type Instance}
import gamekit/registry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/caps/auth as auth_caps
import oskol/caps/ids as ids_caps
import oskol/caps/persistence as persistence_caps
import oskol/caps/rooms as rooms_caps
import oskol/core/ctx.{type Ctx, Ctx}
import oskol/core/envelope
import oskol/core/error
import oskol/fakes
import oskol/guests/prefs
import oskol/handlers/landing
import oskol/rooms/errors
import oskol/rooms/room.{type Table, ActiveRoom, Seat, Table}

fn reading() -> Ctx {
  fakes.ctx()
  |> fakes.with_guests(None)
  |> fakes.with_copy(fakes.sample_copy())
}

// ---------- GET /papi/library ----------

pub fn the_library_lists_every_registered_game_test() {
  let body = landing.library_json(reading(), fakes.no_guest())

  assert string.starts_with(body, "{\"ok\":true,\"games\":[")
  assert string.contains(body, "\"slug\":\"backgammon\"")
  assert !string.contains(body, "\"slug\":\"poker\"")
  // A game map carries what the library grid draws with.
  assert string.contains(body, "\"name\":\"Backgammon\"")
  assert string.contains(body, "\"tagline\":")
  assert string.contains(body, "\"coming_soon\":[]")
}

pub fn the_library_carries_the_guest_it_remembers_test() {
  let ctx = reading() |> fakes.with_guests(Some("Renée"))
  let body = landing.library_json(ctx, fakes.guest("g1"))

  assert string.contains(body, "\"guest_name\":\"Renée\"")
}

pub fn a_visitor_we_do_not_know_has_no_name_test() {
  let body = landing.library_json(reading(), fakes.no_guest())

  assert string.contains(body, "\"guest_name\":null")
}

// ---------- the head an invite link unfurls with ----------

/// A room waiting for its second player: one seat, the creator's.
fn lobby() -> room.ActiveRoom {
  ActiveRoom(
    ..open_room(),
    status: "waiting",
    format: "match7",
    clock: "bg5",
    seats: [#("p1", "Arie", "g1", "")],
    to_act: [],
    clocks: [],
  )
}

pub fn an_open_invite_unfurls_as_who_wants_to_play_what_test() {
  let ctx = reading() |> fakes.with_row(Some(lobby()))

  assert landing.invite_head(ctx, "backgammon", "123456")
    == Some(#(
      "Arie wants to play a match to 7 on a 5 min clock",
      landing.invite_description,
    ))
  assert string.starts_with(
    landing.invite_description,
    "Take the other seat and roll.",
  )
}

pub fn the_invite_names_the_format_as_a_phrase_and_the_clock_only_when_there_is_one_test() {
  let head = fn(format, clock) {
    reading()
    |> fakes.with_row(Some(ActiveRoom(..lobby(), format: format, clock: clock)))
    |> landing.invite_head("backgammon", "123456")
    |> option.map(fn(h) { h.0 })
  }

  assert head("single", "none")
    == Some("Arie wants to play a game of backgammon")
  assert head("match3", "none") == Some("Arie wants to play a match to 3")
  assert head("match5", "blitz")
    == Some("Arie wants to play a match to 5 on a blitz clock")
  assert head("unlimited", "bg10")
    == Some("Arie wants to play unlimited backgammon on a 10 min clock")
  // a format the game no longer lists is still a sentence, not a crash
  assert head("match9", "none") == Some("Arie wants to play backgammon")
}

pub fn the_inviter_is_the_seat_as_the_row_names_it_test() {
  // An account-owned seat's name is the username, put on the row's seat by
  // Elixir before the cap answers; here it is just whatever the seat says.
  let ctx =
    reading()
    |> fakes.with_row(Some(
      ActiveRoom(..lobby(), seats: [#("p1", "arie1", "g9", "u1")]),
    ))

  assert landing.invite_head(ctx, "backgammon", "123456")
    |> option.map(fn(h) { h.0 })
    == Some("arie1 wants to play a match to 7 on a 5 min clock")
}

pub fn any_room_but_a_waiting_one_keeps_the_game_pages_own_head_test() {
  let head = fn(row) {
    reading()
    |> fakes.with_row(row)
    |> landing.invite_head("backgammon", "123456")
  }

  // started, or over: nothing about who played whom
  assert head(Some(ActiveRoom(..lobby(), status: "playing"))) == None
  assert head(Some(open_room())) == None
  assert head(Some(ActiveRoom(..lobby(), status: "finished"))) == None
  // unknown
  assert head(None) == None
  // another game's room under this game's link
  assert head(Some(ActiveRoom(..lobby(), slug: "chess"))) == None
  // a seat with no name, or a lobby the row somehow shows two seats in
  assert head(Some(ActiveRoom(..lobby(), seats: [#("p1", "", "g1", "")])))
    == None
  assert head(Some(
      ActiveRoom(..lobby(), seats: [
        #("p1", "Arie", "g1", ""),
        #("p2", "Bo", "g2", ""),
      ]),
    ))
    == None
}

// ---------- GET /papi/me/games ----------

fn open_room() -> room.ActiveRoom {
  ActiveRoom(
    slug: "backgammon",
    game_id: "123456",
    status: "playing",
    format: "match5",
    clock: "bg5",
    seats: [#("p1", "Alice", "g1", ""), #("p2", "Bob", "g2", "")],
    to_act: ["p1"],
    clocks: [#("p1", 171_000, 0, True), #("p2", 300_000, 0, False)],
    clock_s: 4,
    idle_s: 90,
  )
}

pub fn my_games_lists_the_rooms_this_guest_holds_a_seat_in_test() {
  let ctx = reading() |> fakes.with_active_rooms([open_room()])
  let body = landing.my_games_json(ctx, fakes.guest("g1"))

  assert string.starts_with(body, "{\"ok\":true,\"games\":[{")
  assert string.contains(body, "\"id\":\"123456\"")
  assert string.contains(body, "\"path\":\"/backgammon/123456\"")
  assert string.contains(body, "\"status\":\"playing\"")
  // The other seat is the opponent; the format and the clock by name.
  assert string.contains(body, "\"opponent\":\"Bob\"")
  assert string.contains(body, "\"format\":\"Match to 5\"")
  assert string.contains(body, "\"clock\":\"5 min\"")
  assert string.contains(body, "\"your_move\":true")
  // The clocks from the visitor's side: theirs is running.
  assert string.contains(
    body,
    "\"time\":{\"mine_ms\":171000,\"theirs_ms\":300000,\"running\":\"mine\",\"free_ms\":0,\"age_s\":4}",
  )
  assert string.contains(body, "\"idle_s\":90")
}

pub fn my_games_says_whose_move_from_the_guests_own_seat_test() {
  let ctx = reading() |> fakes.with_active_rooms([open_room()])
  let body = landing.my_games_json(ctx, fakes.guest("g2"))

  assert string.contains(body, "\"opponent\":\"Alice\"")
  assert string.contains(body, "\"your_move\":false")
  assert string.contains(
    body,
    "\"time\":{\"mine_ms\":300000,\"theirs_ms\":171000,\"running\":\"theirs\"",
  )
}

pub fn a_lobby_has_no_opponent_no_clock_and_nobody_to_act_test() {
  let lobby =
    ActiveRoom(
      ..open_room(),
      status: "waiting",
      clock: "none",
      seats: [#("p1", "Alice", "g1", "")],
      to_act: [],
      clocks: [],
      clock_s: 0,
    )
  let ctx = reading() |> fakes.with_active_rooms([lobby])
  let body = landing.my_games_json(ctx, fakes.guest("g1"))

  assert string.contains(body, "\"status\":\"waiting\"")
  assert string.contains(body, "\"opponent\":null")
  assert string.contains(body, "\"clock\":null")
  assert string.contains(body, "\"your_move\":false")
  assert string.contains(body, "\"time\":null")
}

pub fn a_visitor_with_no_guest_holds_no_seat_anywhere_test() {
  // The stub persistence would panic if asked: nobody asks.
  assert landing.my_games_json(reading(), fakes.no_guest())
    == "{\"ok\":true,\"games\":[]}"
}

pub fn my_games_finds_an_owned_seat_from_a_browser_that_never_played_it_test() {
  let owned =
    ActiveRoom(..open_room(), seats: [
      #("p1", "Alice", "g1", "u1"),
      #("p2", "Bob", "g2", ""),
    ])
  let ctx = reading() |> fakes.with_active_rooms([owned])

  // A second device: another guest, the same account. The seat is the
  // account's, so it is this caller's, and the page knows whose move it is.
  let body = landing.my_games_json(ctx, fakes.signed_in("g9", "u1"))

  assert string.contains(body, "\"opponent\":\"Bob\"")
  assert string.contains(body, "\"your_move\":true")
}

pub fn my_games_does_not_hand_an_owned_seat_to_the_guest_that_played_it_test() {
  let owned =
    ActiveRoom(..open_room(), seats: [
      #("p1", "Alice", "g1", "u1"),
      #("p2", "Bob", "g2", ""),
    ])
  let ctx = reading() |> fakes.with_active_rooms([owned])

  // g1 played that seat and then signed in, which stamped it (and would
  // have rotated the guest). A browser still presenting g1 -- logged out,
  // or the next person on that laptop -- holds nothing there, so the game
  // is not offered to it at all.
  let body = landing.my_games_json(ctx, fakes.guest("g1"))
  assert body == "{\"ok\":true,\"games\":[]}"

  // The account sees it, from any browser.
  let mine = landing.my_games_json(ctx, fakes.signed_in("a-new-phone", "u1"))
  assert string.contains(mine, "\"opponent\":\"Bob\"")
}

// ---------- GET /papi/games/:slug ----------

pub fn a_game_page_carries_its_copy_its_formats_and_the_clocks_test() {
  let assert Ok(body) =
    landing.game_json(reading(), fakes.no_guest(), "backgammon")

  assert string.starts_with(body, "{\"ok\":true,\"game\":{")
  assert string.contains(body, "\"slug\":\"backgammon\"")
  assert string.contains(body, "\"min_players\":2")
  assert string.contains(body, "\"max_players\":2")
  assert string.contains(body, "\"default_clock\":")
  // The game's own clocks are preset ids; the presets themselves come with
  // the page, so the picker can name them.
  // Backgammon offers no clock, or 3, 5 or 10 minutes (each with its 12 s
  // delay); the older presets stay defined for old rooms but are not offered.
  assert string.contains(body, "\"clocks\":[\"none\",\"bg3\",\"bg5\",\"bg10\"]")
  assert string.contains(body, "\"clock_presets\":[{\"id\":\"none\"")
  // Formats: a mode is all the creator tunes besides the clock.
  assert string.contains(body, "\"formats\":[{\"id\":\"single\"")
  // Copy, in one object of its own.
  assert string.contains(
    body,
    "\"copy\":{\"title\":\"Play backgammon online with a friend\"",
  )
  assert string.contains(
    body,
    "\"description\":\"Backgammon for two, free, no account needed.\"",
  )
  assert string.contains(
    body,
    "\"intro\":\"The race game with the doubling cube.\"",
  )
  assert string.contains(body, "\"rules\":[\"Fifteen checkers each.\"")
  assert string.contains(
    body,
    "\"faq\":[{\"question\":\"Do we need accounts?\",\"answer\":\"No.\"}]",
  )
  assert string.contains(body, "\"guest_name\":null")
}

pub fn an_unknown_slug_is_a_not_found_envelope_test() {
  let assert Error(err) =
    landing.game_json(reading(), fakes.no_guest(), "checkers")

  assert envelope.error(err)
    == #(
      404,
      "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"No game with that name\"}}",
    )
}

// ---------- POST /papi/games/:slug ----------

/// Caps that mint one code and seat one player — and refuse any setup but
/// `expected`, so what the handler configured the room with is what the
/// test says it is.
fn creating(ctx: Ctx, expected: room.Setup) -> Ctx {
  Ctx(
    ..ctx,
    ids: ids_caps.IdsCaps(..ids_caps.stub(), game_code: fn() { "123456" }),
    persistence: persistence_caps.PersistenceCaps(
      ..ctx.persistence,
      game_exists: fn(_) { False },
    ),
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      spawn: fn(_, _) { Ok(Nil) },
      subscribe: fn(_) { Nil },
      configure: fn(_, setup) {
        case setup == expected {
          True -> Ok(Nil)
          False ->
            Error(errors.Other("configured with " <> string.inspect(setup)))
        }
      },
      join: fn(_, _, _, _) { Ok(Seat(player_id: "p1", started: False)) },
    ),
  )
}

pub fn creating_a_game_answers_with_its_code_and_the_seat_url_test() {
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", clock: "bg3"))

  assert landing.create_json(
      ctx,
      fakes.guest("g1"),
      "backgammon",
      "single",
      "Alice",
      "bg3",
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456\",\"player_id\":\"p1\"}",
    )
}

pub fn the_creators_mode_and_clock_reach_the_room_test() {
  let ctx =
    reading()
    |> creating(room.Setup(format: "match5", clock: "bg10"))

  let assert Ok(_) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "match5",
      "Alice",
      "bg10",
    )
}

pub fn no_clock_asked_for_means_the_games_default_test() {
  // Backgammon's default preset, straight from its own Info.
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", clock: "none"))

  let assert Ok(_) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "single",
      "Alice",
      "",
    )
}

pub fn creating_a_game_needs_a_name_test() {
  let ctx =
    reading()
    |> creating(room.Setup(format: "single", clock: "none"))

  let assert Error(err) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "single",
      " ",
      "none",
    )

  assert envelope.error(err)
    == #(
      422,
      "{\"ok\":false,\"error\":{\"code\":\"validation_failed\",\"message\":\"Pick a display name first\"}}",
    )
}

pub fn creating_a_game_in_a_mode_it_has_not_got_is_refused_test() {
  let ctx = reading() |> creating(room.Setup("single", "none"))
  let ctx =
    Ctx(
      ..ctx,
      rooms: rooms_caps.RoomsCaps(..ctx.rooms, configure: fn(_, _) {
        Error(errors.UnknownFormat)
      }),
    )

  let assert Error(err) =
    landing.create_json(
      ctx,
      fakes.no_guest(),
      "backgammon",
      "nope",
      "Alice",
      "none",
    )

  assert error.code(err) == "validation_failed"
  assert error.message(err) == "Unknown game mode"
}

pub fn creating_a_game_of_a_game_that_does_not_exist_is_not_found_test() {
  let assert Error(err) =
    landing.create_json(
      reading(),
      fakes.no_guest(),
      "checkers",
      "x",
      "Alice",
      "none",
    )

  assert error.status(err) == 404
}

// ---------- GET /papi/games/:slug/rooms/:id ----------

fn table(ctx: Ctx, table: Table) -> Ctx {
  fakes.with_room(ctx, Some(fakes.room()), Some(table))
}

pub fn an_invite_to_a_free_seat_is_open_test() {
  let ctx =
    reading()
    |> table(
      Table(
        full: False,
        inviter: Some("Alice"),
        summary: "Match to 3 · Blitz clock",
        disconnected: [],
      ),
    )

  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"open\",\"inviter_name\":\"Alice\",\"summary\":\"Match to 3 · Blitz clock\",\"disconnected\":[]}"
}

pub fn an_invite_to_a_full_table_offers_nothing_test() {
  let ctx =
    reading()
    |> table(
      Table(
        full: True,
        inviter: Some("Alice"),
        summary: "Single game",
        disconnected: [],
      ),
    )

  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"full\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[]}"
}

pub fn an_invite_to_a_table_someone_left_offers_their_seat_test() {
  let ctx =
    reading()
    |> table(
      Table(full: True, inviter: None, summary: "Single game", disconnected: [
        #("p2", "Bob", False),
      ]),
    )

  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"away\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[{\"id\":\"p2\",\"name\":\"Bob\"}]}"
}

pub fn an_invite_to_a_seat_the_caller_already_holds_sends_it_to_the_table_test() {
  // The account's seat is away (its tab closed), and the account arrives
  // from JOIN GAME on another device. The seat is its own: no door, the
  // table.
  let ctx =
    reading()
    |> table(
      Table(full: True, inviter: None, summary: "Single game", disconnected: [
        #("p1", "Alice", True),
      ]),
    )
    |> fn(ctx) {
      Ctx(
        ..ctx,
        rooms: rooms_caps.RoomsCaps(..ctx.rooms, seated_game: fn(id, _, user) {
          assert id == "123456"
          case user {
            Some("u1") -> Ok(#("p1", a_running_game()))
            _ -> Error(errors.NoSeat)
          }
        }),
      )
    }

  assert landing.room_json(
      ctx,
      fakes.signed_in("a-new-phone", "u1"),
      "backgammon",
      "123456",
    )
    == "{\"ok\":true,\"state\":\"seated\",\"path\":\"/backgammon/123456\"}"

  // Anyone else still gets the invite's own answer.
  assert landing.room_json(ctx, fakes.guest("stranger"), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"owned\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[]}"
}

pub fn an_invite_to_a_room_that_is_over_is_missing_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"missing\",\"inviter_name\":null,\"summary\":null,\"disconnected\":[]}"
}

pub fn an_invite_to_a_table_whose_away_seat_is_owned_offers_nothing_test() {
  let ctx =
    reading()
    |> table(
      Table(full: True, inviter: None, summary: "Single game", disconnected: [
        #("p2", "Bob", True),
      ]),
    )

  // The seat is an account's: the state says so, and the seat is not even
  // named, so nothing on the page can be typed at it.
  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"owned\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[]}"
}

pub fn an_invite_offers_only_the_away_seats_no_account_owns_test() {
  let ctx =
    reading()
    |> table(
      Table(full: True, inviter: None, summary: "Single game", disconnected: [
        #("p1", "Alice", True),
        #("p2", "Bob", False),
      ]),
    )

  assert landing.room_json(ctx, fakes.no_guest(), "backgammon", "123456")
    == "{\"ok\":true,\"state\":\"away\",\"inviter_name\":null,\"summary\":\"Single game\",\"disconnected\":[{\"id\":\"p2\",\"name\":\"Bob\"}]}"
}

// ---------- POST /papi/games/:slug/rooms/:id ----------

fn seating(ctx: Ctx, seat: Result(room.Seat, errors.RoomError)) -> Ctx {
  let ctx = fakes.with_room(ctx, Some(fakes.room()), Some(a_table()))

  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      subscribe: fn(_) { Nil },
      join: fn(_, _, _, _) { seat },
      claim: fn(_, _, _, _) { seat },
    ),
  )
}

fn a_table() -> Table {
  Table(full: True, inviter: None, summary: "Single game", disconnected: [
    #("p2", "Bob", False),
  ])
}

pub fn joining_answers_with_the_url_that_opens_the_seat_test() {
  let ctx =
    reading()
    |> fakes.with_guests(None)
    |> seating(Ok(Seat(player_id: "p2", started: True)))

  assert landing.join_json(
      ctx,
      fakes.guest("g2"),
      "backgammon",
      "123456",
      "Bob",
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456\",\"player_id\":\"p2\"}",
    )
}

pub fn joining_a_room_that_is_over_is_not_found_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Bob")

  assert error.status(err) == 404
  assert error.message(err)
    == "That game is over. Start a new one and send a fresh link."
}

pub fn joining_a_table_that_filled_up_says_so_test() {
  let ctx = reading() |> seating(Error(errors.GameFull))

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Bob")

  assert error.code(err) == "validation_failed"
  assert error.message(err) == "That game is full"
}

pub fn a_signed_in_player_whose_username_is_taken_at_the_table_is_numbered_test() {
  // A guest at the table typed "Sam"; the account "Sam" has no name field
  // to change, so it sits down as "Sam1".
  let ctx =
    reading()
    |> fakes.with_guests(None)
    |> seating(Ok(Seat(player_id: "p2", started: True)))
    |> fn(ctx) {
      Ctx(
        ..ctx,
        auth: auth_caps.AuthCaps(..ctx.auth, user: fn(_) {
          Some(auth_caps.User(
            id: "u1",
            email: "sam@example.com",
            name: Some("Sam"),
          ))
        }),
        rooms: rooms_caps.RoomsCaps(..ctx.rooms, join: fn(_, name, _, _) {
          case name {
            "Sam" -> Error(errors.NameTaken)
            _ -> {
              assert name == "Sam1"
              Ok(Seat(player_id: "p2", started: True))
            }
          }
        }),
      )
    }

  let assert Ok(_) =
    landing.join_json(
      ctx,
      fakes.signed_in("g2", "u1"),
      "backgammon",
      "123456",
      "",
    )
}

pub fn a_name_clash_is_refused_test() {
  let ctx = reading() |> seating(Error(errors.NameTaken))

  let assert Error(err) =
    landing.join_json(ctx, fakes.no_guest(), "backgammon", "123456", "Alice")

  assert error.message(err) == "That name is already taken"
}

pub fn reclaiming_a_seat_hands_out_the_rooms_plain_url_test() {
  // Nothing secret comes back: the seat is now held by the guest that
  // claimed it, and the URL is the one anybody would be given.
  let ctx =
    reading()
    |> seating(Ok(Seat(player_id: "p2", started: True)))

  assert landing.claim_json(
      ctx,
      fakes.guest("g2"),
      "backgammon",
      "123456",
      "p2",
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456\",\"player_id\":\"p2\"}",
    )
}

pub fn a_claim_hands_the_seat_to_the_guest_that_asked_test() {
  // Which guest claimed is what the room is told: that is what holds the
  // seat afterwards.
  let ctx =
    reading()
    |> fakes.with_room(Some(fakes.room()), Some(a_table()))

  let ctx =
    Ctx(
      ..ctx,
      rooms: rooms_caps.RoomsCaps(
        ..ctx.rooms,
        subscribe: fn(_) { Nil },
        claim: fn(_, player_id, guest_id, _) {
          case player_id == "p2" && guest_id == Some("g2") {
            True -> Ok(Seat(player_id: "p2", started: True))
            False -> Error(errors.PlayerNotFound)
          }
        },
      ),
    )

  assert landing.claim_json(
      ctx,
      fakes.guest("g2"),
      "backgammon",
      "123456",
      "p2",
    )
    == Ok(
      "{\"ok\":true,\"id\":\"123456\",\"path\":\"/backgammon/123456\",\"player_id\":\"p2\"}",
    )

  let assert Error(err) =
    landing.claim_json(ctx, fakes.no_guest(), "backgammon", "123456", "p2")

  assert error.message(err) == "That player is not at this table"
}

pub fn reclaiming_a_seat_whose_player_came_back_is_refused_test() {
  let ctx = reading() |> seating(Error(errors.SeatConnected))

  let assert Error(err) =
    landing.claim_json(ctx, fakes.guest("g2"), "backgammon", "123456", "p2")

  assert error.message(err) == "That player is back at the table"
}

// ---------- GET /papi/codes/:code ----------

pub fn a_code_resolves_to_the_game_it_belongs_to_test() {
  let ctx =
    reading()
    |> fakes.with_room(Some(fakes.room()), None)
    |> fakes.with_slug(Some("backgammon"))

  assert landing.code_json(ctx, "123456")
    == Ok("{\"ok\":true,\"slug\":\"backgammon\",\"code\":\"123456\"}")
}

pub fn a_code_typed_with_lookalikes_still_finds_its_room_test() {
  // Read down the phone and typed back in lower case, with an O for a zero
  // and an l for a one. Nothing answers to what was typed, so the
  // normalised form is tried, and that is the name that comes back.
  let ctx =
    reading()
    |> rooms_at(["AB10XZ"])

  assert landing.code_json(ctx, "ablOxz")
    == Ok("{\"ok\":true,\"slug\":\"backgammon\",\"code\":\"AB10XZ\"}")
}

pub fn a_code_is_looked_up_as_typed_first_test() {
  // A room's own name is the truth about it: normalising is only the
  // fallback, so an id that is not code-shaped is never mangled.
  let ctx = reading() |> rooms_at(["t-9f3c1a"])

  assert landing.code_json(ctx, "t-9f3c1a")
    == Ok("{\"ok\":true,\"slug\":\"backgammon\",\"code\":\"t-9f3c1a\"}")
}

/// Caps where exactly these codes name a live backgammon room.
fn rooms_at(ctx: Ctx, codes: List(String)) -> Ctx {
  Ctx(
    ..ctx,
    rooms: rooms_caps.RoomsCaps(
      ..ctx.rooms,
      find: fn(id) {
        case list.contains(codes, id) {
          True -> Some(fakes.room())
          False -> None
        }
      },
      resume: fn(_) { None },
      slug_of: fn(id) {
        case list.contains(codes, id) {
          True -> Some("backgammon")
          False -> None
        }
      },
    ),
  )
}

pub fn a_code_nothing_answers_to_is_not_found_test() {
  let ctx = reading() |> fakes.with_room(None, None)

  let assert Error(err) = landing.code_json(ctx, "123456")

  assert envelope.error(err)
    == #(
      404,
      "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"No game with that code\"}}",
    )
}

// ---------- GET/POST /papi/me/prefs ----------

pub fn a_guest_who_never_picked_gets_the_midnight_board_test() {
  // The board the home page wears, and one a guest may keep.
  assert prefs.default_backgammon_theme() == "midnight"
  assert prefs.validate("backgammon_theme", prefs.default_backgammon_theme())
    == Ok(#("backgammon_theme", "midnight"))
}

pub fn a_visitor_with_no_guest_id_has_no_preferences_test() {
  let body = landing.prefs_json(fakes.ctx(), fakes.no_guest())

  assert body == "{\"ok\":true,\"prefs\":{}}"
}

pub fn the_board_a_guest_picked_comes_back_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_prefs([#("backgammon_theme", "midnight")], #("", ""))

  let body = landing.prefs_json(ctx, fakes.guest("g1"))

  assert string.contains(body, "\"backgammon_theme\":\"midnight\"")
}

pub fn a_preference_written_by_an_older_release_is_dropped_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_prefs(
      [#("backgammon_theme", "burlwood"), #("something_else", "x")],
      #("", ""),
    )

  let body = landing.prefs_json(ctx, fakes.guest("g1"))

  assert body == "{\"ok\":true,\"prefs\":{}}"
}

pub fn picking_a_board_keeps_it_test() {
  let ctx =
    fakes.ctx()
    |> fakes.with_prefs([#("backgammon_theme", "forest")], #(
      "backgammon_theme",
      "forest",
    ))

  let assert Ok(body) =
    landing.save_pref_json(ctx, fakes.guest("g1"), "backgammon_theme", "forest")

  assert string.contains(body, "\"backgammon_theme\":\"forest\"")
}

pub fn a_board_that_does_not_exist_is_refused_test() {
  // The stub's `save_pref` panics on any write, so reaching IO here would
  // fail the test: a rejected value must never be written.
  let assert Error(err) =
    landing.save_pref_json(
      fakes.ctx(),
      fakes.guest("g1"),
      "backgammon_theme",
      "plaid",
    )

  assert error.status(err) == 422
  assert error.code(err) == "validation_failed"
  assert error.message(err) == "That is not one of the board themes"
}

pub fn a_preference_the_site_does_not_keep_is_refused_test() {
  let assert Error(err) =
    landing.save_pref_json(fakes.ctx(), fakes.guest("g1"), "admin", "true")

  assert error.status(err) == 422
  assert error.message(err) == "Unknown preference"
}

/// A backgammon game started and left alone: all `seated_game` needs to
/// answer with. The invite never reads it.
fn a_running_game() -> Instance {
  let assert Ok(entry) = registry.find("backgammon")
  let assert Ok(game) =
    entry.start(
      "single",
      [gk_game.Seat("p1", "Alice"), gk_game.Seat("p2", "Bob")],
      7,
      clock.NoClock,
      0,
    )
  game
}
