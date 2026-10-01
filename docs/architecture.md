# Architecture

How Oskol is put together: the product in brief, the three layers, the game
contract and protocol, time controls, and the Gleam-decides / Elixir-does-IO
pattern. Seats, guests and accounts are in [identity.md](identity.md); rooms,
persistence and the bot in [rooms.md](rooms.md).

## The product in brief
Oskol (oskol.io) is a backgammon site. The mission: become the best place on
the internet to play backgammon. You play a friend from a link: no account
needed, phone-friendly, free. The game is the real thing, by the book, and every
game is graded by the analysis engine once it is over: play a friend from
a link, then learn from the game.
**Backgammon** is the classic race game: a single game (no cube), matches
to 3, 5, 7, 11, 15 or 21 with the cube and the Crawford rule, or unlimited
play with the cube and the Jacoby rule (`src/backgammon/game.gleam`). A roll that can play nothing is a state, not a skipped turn:
the dice stand for both players under "no legal moves" until the mover
passes, and every time control gives each turn its first 12 seconds free.
Between the games of a match (or of unlimited play) the finished game's
position stays up, nobody is on the clock, and the next game starts when
both players have pressed READY. Unlimited play has no finish line of its
own, so beside READY either player may END SESSION: the score stands and
whoever is ahead has won. A match ends when somebody reaches the target and
is never closable, and a game on the board is left by resigning. Every game can be played with an optional
time control.

Poker, go and chess were removed (the repository history keeps them). Their old links (`/poker`, `/go`,
`/chess`, with or without a room id or `?game=`) redirect to `/`
(`OskolWeb.RemovedGameController`), and `/papi/games/<slug>` for them is a
404 like any slug that names no game.

The game is built on **gamekit**, a small framework that keeps the rules,
the room and the client apart: a game is one Gleam module that implements
the contract below, and the server and the protocol are generic. Backgammon
is the only game registered, and it is the product; the framework stays
because the separation is what keeps the rules pure, seeded and testable.

**Tech stack:** Gleam (the game + framework), Elixir/Phoenix (platform host),
Elm (client), Tailwind CSS.

## Architecture in one picture

```
Gleam games ──(contract)──> gamekit host ──(opaque instance + JSON)──> Elixir room
                                                                          │
Elm client <──(protocol: scene, legal, outcome, events, clock)── Phoenix channel <──┘
```

Three layers, two fixed boundaries:

1. **Gleam owns the game** (`src/gamekit/`, `src/backgammon/`).
   Pure, seeded, tested.
2. **Elixir owns the platform** (`lib/`). Rooms, setup, reconnect, rematch,
   routes. It never sees a checker or a die: it calls `Oskol.GameKit`, which
   wraps `gamekit/host` and speaks only opaque instances and JSON.
3. **Elm owns the client** (`assets/src/`). One `Browser.application` owns
   every URL: the library, a game's start page, and the table. It decodes the
   fixed protocol and renders the backgammon board from it, and reads the
   landing pages' data from a JSON API (`/papi`). Elixir serves the SPA shell
   with the head a crawler needs, and nothing else.

## The game contract (`src/gamekit/game.gleam`)

```gleam
Game(
  info:          Info,                                      // slug, name, formats, clocks, default clock
  init:          fn(Config, List(Seat), Rng) -> Result(state, String),
  decode_action: fn(action.Incoming) -> Result(action, String),
  apply:         fn(state, PlayerId, action) -> Result(#(state, List(Event)), String),
  legal:         fn(state, PlayerId) -> List(Schema),       // what this player may do now
  scene:         fn(state, Viewer) -> Scene,                // per-viewer projection
  outcome:       fn(state) -> Outcome,
  clocks:        fn(state) -> List(PlayerId),               // who is on the clock right now
  timeout:       fn(state, PlayerId) -> Timeout(action),    // Forfeit, or Act(action) taken for them
  record:        fn(state) -> Option(Json),                 // the whole public record, or game.no_record
  committed:     fn(state, action, state) -> Option(Json),  // what this step committed, or game.no_committed
  bot:           fn(state, PlayerId, Ask, Int) -> Result(List(Json), String),  // what a bot seat does now
)
```

`bot` is what a seat nobody is sitting at does: the actions to take, in
order, as the same `{"name", "params"}` objects a browser sends. `Ask` is the
analysis engine as a closure (`fn(route, body) -> Result(body, String)`), so
the brain stays pure and the platform owns the socket, the timeout and the
retries. The `Int` is how many asks have already come back empty for this
decision, and what to do once that is too many is the game's call -- which is
why Elixir never learns the word "resign". `game.no_bot` is the default for a
game nothing plays for you.

`record` is what `GET /papi/games/:slug/rooms/:id/record` serves to anyone
with the room: everything a replay or an analysis needs, too big to ride in every update.
Backgammon's is every game of the match with every turn (notation, the
position and cube it left, where the moved checkers `landed`); its scene
carries only the game on the board plus one result line per finished game.

`committed` is a unit of play the platform may start working on before the
game is over. It reads a transition (the state before the action, the action,
the state after) because a commit is not a state; it is carried on the
`Instance` the step returned and read with `Oskol.GameKit.committed/1`. Like
`record` it may hold only what every seat has already seen, because it travels
off the room. Backgammon's is a played turn, as the analysis engine takes it
(`backgammon/analysis.committed_json`), which is what lets a turn be graded
while the game goes on; `game.no_committed` is the answer for a game with no
such unit.

A format is a name and a config the game reads (`game.config_get`): all
the creator tunes is the format and the clock. `Info.clocks` lists the
time-control presets a game offers and `default_clock` the one
preselected.

Rules that keep this honest:
- **All randomness goes through `gamekit/rng`** stored in the state. Never
  `int.random` or `list.shuffle`. A game is its seed plus its action log.
- **`apply` validates and never mutates on error.** It returns events for
  every state change; the client animates from events, not from diffing.
- **No presentation in the engine.** No animation flags, no wizard state.
  Multi-step interactions are action schemas with candidates.
- **Ids are deterministic and opaque.** Checkers are `"w1".."b15"`. An id
  never reveals a face. Faces travel as token props.
- **Hidden information is the projection's job, and the host's.** `scene`
  decides per viewer: `scene.hidden_zone` sends a count only,
  `scene.hidden(token)` keeps an id but drops face and props. Events are
  emitted once for everyone; the host runs them through
  `event.for_viewer(events, viewer_scene)`, which blanks the id of any
  `token_moved` whose token the viewer's scene does not show and drops
  reveals they cannot see. `custom` payloads are not filtered: never put
  one viewer's secret in one.
- **Sort before you serialise a dict keyed by a custom type.** Erlang orders
  atom keys by atom-table index, which differs between VMs, so unsorted
  `dict.to_list` output makes scene JSON (and golden fingerprints)
  irreproducible.
- **Games never read the time.** `clocks(state)` names the players who should
  be charged right now. `gamekit/clock` owns the arithmetic, `gamekit/instance`
  applies it with the host's `now`, and when a clock runs out the instance
  asks `timeout`: backgammon forfeits (a game may instead `Act` for the
  player and play on). An action that arrives after a clock ran
  out is applied after the timeout if it is still legal, never instead of
  it. Clock-driven turns do not count as room activity: a table nobody is
  at still goes idle after an hour.

## The protocol (`src/gamekit/scene.gleam`, `event.gleam`, `action.gleam`)

The client only ever decodes these:
- **Scene**: `players` (counters, flags, data) and `zones` of `tokens` with
  stable ids, a `face`, and `props`; plus a narrow `data` escape hatch.
- **Events**: `token_moved`, `counter_changed`, `revealed`, `phase_changed`,
  `message`, or `custom(kind, payload)` for bespoke views.
- **Schemas**: legal actions as `{name, label, params}` where a `select` param
  carries its zone and candidate ids, a `choice` its options, a `number` its
  bounds.
- **Outcome**: `ongoing` or `finished(winners)`.
- **Clock**: `enabled`, `label`, per-player `remaining_ms`, `move_ms` (free
  time left on this move) and `running`, `timed_out`.

Actions in: `{"name": "<action>", "params": {...}}`. Legal actions may
be enumerated (backgammon sends one `move` schema per legal move) or
described with bounds. Hidden information is resolved by the `scene`
projection per viewer: in backgammon the mover stages moves (`move`, `undo`)
that only their own scene shows, and commits them with `play`.

### Time controls
Presets live in `gamekit/clock.presets()`: Fischer, Bronstein and per-move.
A game lists which presets it offers. Backgammon offers `none` (the default)
and `bg3`, `bg5`, `bg10`, `bg15`, `bg30`, `bg60`: a plain bank each, with
the turn delay below doing the rest. The older presets (`blitz`, `rapid`,
`delay`, `per_move`) stay in the list because rooms made under them still
carry and replay them; they are no longer offered. A game may also declare a **turn delay** (`Info.turn_delay_ms`,
applied by `instance.start` through `clock.with_turn_delay`): the first N
milliseconds of every turn are free under every control, and unused delay is
never banked. It overlaps rather than stacks with a control's own free time
(the longer of the two wins). Backgammon takes 12 seconds, which is what
live play does and what the dice animation runs inside; the default is
zero. The Elixir room schedules a tick for the next possible expiry and
calls `GameKit.expire/2`, which applies the game's `timeout`.

## Platform decisions live in Gleam (`src/oskol/`)

Games were always Gleam. So is the platform's decision-making: what a name
has to be, when a game code is free, what an invite link offers, what a
refusal says, what a JSON page carries. The rule is the same one the games
follow — Gleam is pure, Elixir does the IO:

```
Phoenix (router, plugs, controllers, GenServers)       [Elixir, thin]
  -> handler(ctx, session, request)                    [GLEAM, all decisions]
       ctx.<domain>.<cap>(...) performs injected IO
  -> JSON on the wire                                  [Elixir, thin]
```

- `Ctx` (src/oskol/core/ctx.gleam) is a record of capability closures, one
  group per domain, built by `Oskol.Gleam.CtxBuilder.build/1`. Each
  `src/oskol/caps/<d>.gleam` has an Elixir twin at
  `lib/oskol/gleam/caps/<d>.ex`; they must agree on constructor tag and
  field order (a Gleam record is a tagged tuple).
- `Session` is the caller: a guest id (or nothing), and the account signed
  in on that browser (or nothing). The guest id is the cookie; the account
  is read off the guest row once per request.
- Caps are fine-grained and speak the domain types in `src/oskol/*` — never
  Ecto structs or raw maps. A room process crosses as the opaque
  `rooms/room.Room`.
- Caps whose failure is product behaviour return `Result` and the handler
  turns it into the sentence a player reads (`rooms/errors.message`).
  Everything else raises Elixir-side and surfaces as a 500.
- Tests build a `Ctx` of stubs that panic (`test/oskol/fakes.gleam`), so a
  handler test that reaches IO it did not arrange for fails loudly.
- `Oskol.Game` (minting a code, finding a room) and the `/papi` controller
  are two doors onto the same handlers, so nothing that decides anything
  exists twice.

## Adding a game
Backgammon is the product and the only game registered, but the framework
still takes another one:
1. Create `src/<slug>/game.gleam` implementing `gamekit/game.Game`. Give
   `Info` its formats, the clock presets it offers, and a `timeout` policy.
2. Register it in `src/gamekit/registry.gleam` (`all()`).
3. Add `test/<slug>/conformance_test.gleam` using `gamekit/conformance`
   (random playouts to termination, replay determinism, your invariants),
   then `mix oskol.fixtures` so the golden and Elm suites cover it.
4. Its formats show up on the create page. It needs an Elm view in
   `assets/src/Games/<Name>/View.elm`, dispatched by slug in
   `Page/Play.elm`; the view reads the protocol Scene, never new wire types
   (see `assets/src/Games/Backgammon/View.elm`). There is no generic
   renderer; the repository history has one to start from.
5. Pick a slug that is not one of the removed games' (`poker`, `go`,
   `chess`): the router sends those home before any game route sees them.

## Future
- A bot for a game that is not backgammon: `Game.bot` is the seam, and
  `game.no_bot` is what every other game would start from.
