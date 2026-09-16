# Oskol - backgammon, from a link

## Project Overview
Oskol (oskol.io) is a backgammon site. The mission: become the best place on
the internet to play backgammon. You play a friend from a link: no accounts,
phone-friendly, free. The game is the real thing first, and offers optional
twists that throw the book out (picking your dice once a game today, a
reroll later).
**Backgammon** is the classic race game with the doubling cube: single games,
matches to 3, 5 or 7 with the Crawford rule, or unlimited play with the
Jacoby rule. A roll that can play nothing is a state, not a skipped turn:
the dice stand for both players under "no legal moves" until the mover
passes, and every time control gives each turn its first 12 seconds free.
Between the games of a match (or of unlimited play) the finished game's
position stays up, nobody is on the clock, and the next game starts when
both players have pressed READY. Every game can be played with an optional
time control.

Oskol used to host poker, go and chess too; they were removed in the pivot
(the repository history keeps them). Their old links (`/poker`, `/go`,
`/chess`, with or without a room id or `?game=`) redirect to `/`
(`OskolWeb.RemovedGameController`), and `/papi/games/<slug>` for them is a
404 like any slug that names no game.

The first player picks everything (mode, settings, clock), shares a link, and
the game starts the moment the second player types a name. **A seat is held
by the guest cookie that took it** (`OskolWeb.Plugs.GuestId`: opaque,
HttpOnly, year-long), and no URL anywhere carries a secret: a player's link
is the plain room URL. A seat whose holder is away can be claimed from the
invite link by anyone with the room code -- friends playing, not security --
and it is that browser's from then on. One browser holds one seat at a
table: a guest already seated there is refused a second. The room code is
therefore the only thing between a stranger and a live game, so a code is
six characters of a 32-letter alphabet (about 1.07 billion), not six digits.
A display name is display only and grants nothing. A socket also names its
**client** (a per-tab id the browser mints; it authenticates nothing): the
room compares it with itself to tell one tab reconnecting -- a reload, a
route change, a phone waking its websocket up -- from another tab taking the
seat over, which is the only case the connection that had it is told about
(`src/oskol/rooms/seat.gleam`). Accounts are the plan, and the guest is what
becomes one (`guests.user_id`), which is why identity has no second
mechanism beside it.

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
  info:          Info,                                      // slug, name, formats (+settings), clocks, default clock
  init:          fn(Config, List(Seat), Rng) -> Result(state, String),
  decode_action: fn(action.Incoming) -> Result(action, String),
  apply:         fn(state, PlayerId, action) -> Result(#(state, List(Event)), String),
  legal:         fn(state, PlayerId) -> List(Schema),       // what this player may do now
  scene:         fn(state, Viewer) -> Scene,                // per-viewer projection
  outcome:       fn(state) -> Outcome,
  clocks:        fn(state) -> List(PlayerId),               // who is on the clock right now
  timeout:       fn(state, PlayerId) -> Timeout(action),    // Forfeit, or Act(action) taken for them
  record:        fn(state) -> Option(Json),                 // the whole public record, or game.no_record
)
```

`record` is what `GET /papi/games/:slug/rooms/:id/record` serves to anyone
with the room: everything a replay or an analysis needs, too big to ride in every update.
Backgammon's is every game of the match with every turn (notation, the
position and cube it left, where the moved checkers `landed`); its scene
carries only the game on the board plus one result line per finished game.

Formats carry **settings**: each is a list of choices with a default, and
picking a choice merges its config entries (`game.configure`). That is how
twists are offered (backgammon's "Pick dice"). `Info.clocks` lists the time-control presets a game offers and
`default_clock` the one preselected.

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
A game lists which presets it offers. A game may also declare a **turn delay** (`Info.turn_delay_ms`,
applied by `instance.start` through `clock.with_turn_delay`): the first N
milliseconds of every turn are free under every control, and unused delay is
never banked. It overlaps rather than stacks with a control's own free time
(the longer of the two wins). Backgammon takes 12 seconds, which is what
live play does and what the dice animation runs inside; the default is
zero. The Elixir room schedules a tick for the next possible expiry and
calls `GameKit.expire/2`, which applies the game's `timeout`.

## File map

```
src/gamekit/        framework: rng, scene, event, action, game, clock, instance
                    (typed `Running`, and the `Instance` that erases it),
                    replay (a log folded through the typed steps),
                    registry (add games here), host (Elixir surface),
                    text (agent/test rendering), conformance, fixture
src/backgammon/     Backgammon: board (rules + move generation), state (turns,
                    dice, cube, match play), engine, projection, game,
                    analysis (the analysis engine's board, a game's turns)
src/oskol/          the platform's own decisions, in Gleam (see "Platform
                    decisions live in Gleam" below): core (ctx, session,
                    error, envelope), caps (the IO a handler may do),
                    rooms (codes, names, errors, invite), guests/identity,
                    landing/copy, reviews/report, handlers (rooms, landing,
                    reviews)
test/gamekit/       protocol, rng, clock, action, event, golden replays
test/oskol/         handler and rule tests on stub capabilities (fakes.gleam)
test/backgammon/    board rules, engine, cube, oracle, properties, turns
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: setup, auto-start, actions, clocks, rematch
lib/oskol/persistence.ex        games + game_actions tables (seed + action log per room)
lib/oskol/guests.ex             silent guest identity: guests table (name + prefs) + placeholder users
lib/oskol_web/plugs/guest_id.ex mints/renews the year-long guest cookie on every visit
lib/oskol/game/persister.ex     write-behind: rooms cast, one process writes in order
lib/oskol/game/rehydrator.ex    rebuild a room from the log on lookup (deploys, idle stops)
lib/oskol/game/pruner.ex        deletes unfinished games idle > 3 days; finished ones stay
lib/oskol/reviews.ex            game_reviews table, the log a review reads, the engine's HTTP
lib/oskol/reviews/queue.ex      runs post-game reviews one room at a time, off the room
lib/oskol/game/ready_up_patch.ex  one-off: old match logs get the READYs the engine now waits for
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
src/oskol/rooms/seat.gleam       what an attach means: the same client back, or a takeover
src/oskol/rooms/code.gleam       the shape of a room code, and how a typed one is read
lib/oskol_web/controllers/spa_controller.ex    "/" and "/:slug": the SPA shell
                                 plus the title, description, canonical, og
                                 and JSON-LD a crawler reads
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the same client
lib/oskol_web/controllers/removed_game_controller.ex   old /poker, /go, /chess links -> "/"
lib/oskol/gleam/ctx_builder.ex   builds the Gleam Ctx and Session for a caller
lib/oskol/gleam/caps/*.ex        the real IO behind src/oskol/caps/*.gleam
lib/oskol_web/controllers/api/landing_controller.ex   /papi JSON for the Elm client
assets/src/Main.elm              SPA shell: routes, page dispatch, JOIN GAME
assets/src/Route.elm             the three client routes, mirroring the server's
assets/src/Api.elm               the /papi envelope + CSRF header
assets/src/Api/Catalog.elm       the landing pages' data and its decoders
assets/src/Page/GameLanding.elm  "/" the home page (CREATE GAME's dialog, the theme
                                 picker) and "/:slug?game=" what an invite offers
assets/src/Page/HomeBoard.elm    the home page's board: the table edge to edge, the
                                 2x2 menu in its right band
assets/src/Page/Play.elm         "/:slug/:id" the table, and the lobby before it
assets/src/Page/Replay.elm       "/:slug/:id/replay" a room's games played again, with the
                                 engine's analysis (polls /reviews while any is pending)
assets/src/Games/Backgammon/Replay.elm  the record and reviews as the replay reads them:
                                 decoders, the board at each step, verdicts per record line
assets/src/Ui/Shell.elm          the OSKOL wordmark, the code prompt, the footer
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Backgammon/View.elm  the backgammon board
assets/src/View/Clock.elm        clock display
assets/css/app.css               the multicade/notebook design system (paper, pixel,
                                 pix, btn-arcade, tile, bg-board...)
                                 plus the landing's quiet notebook (quiet, q-card,
                                 q-title, q-eyebrow, q-opt, q-btn, q-field)
                                 and the eight backgammon boards (.bg-theme-*)
src/oskol/guests/prefs.gleam     the display preferences a guest may keep, and
                                 the values each one allows
```

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
- `Session` is the caller: a guest id, or nothing. It authenticates nothing.
- Caps are fine-grained and speak the domain types in `src/oskol/*` — never
  Ecto structs or raw maps. A room process crosses as the opaque
  `rooms/room.Room`.
- Caps whose failure is product behaviour return `Result` and the handler
  turns it into the sentence a player reads (`rooms/errors.message`).
  Everything else raises Elixir-side and surfaces as a 500, as before.
- Tests build a `Ctx` of stubs that panic (`test/oskol/fakes.gleam`), so a
  handler test that reaches IO it did not arrange for fails loudly.
- `Oskol.Game` (minting a code, finding a room) and the `/papi` controller
  are two doors onto the same handlers, so nothing that decides anything
  exists twice.

## URLs

All three are Elm routes, and all three are server routes: a visitor may
arrive at any of them cold, and moving between them afterwards is a
`pushUrl`, not a page load.

- `/` the home page (the library, listing backgammon)
- `/papi/library`, `/papi/games/:slug` (GET and POST) the landing pages as
  JSON for the Elm client. Public like the pages, session-based guest
  identity, CSRF token in `x-csrf-token`. Envelope: `{"ok": true, ...}` or
  `{"ok": false, "error": {"code", "message"}}` (404 not_found,
  422 validation_failed, 500 server_error).
- `/backgammon` create a game; `/backgammon?game=<id>` is the invite link
- `/backgammon/<id>` a running game — and, until the second player arrives,
  the waiting room: a room with no instance yet answers the game channel
  with a lobby payload. The URL says which room and nothing else; what it
  opens is the room's answer on the game channel, against the browser's
  guest cookie. A browser holding no seat there is refused ("unauthorized",
  never saying why) and the client sends it to the invite link, which is the
  one page that says whether there is a seat to take. A `?t=` from a link
  minted before seat tokens were dropped is ignored by every route and every
  handler.
- `/backgammon/<id>/replay?game=<n>` a room's games played again,
  a line of the record at a time, with the analysis engine's verdicts. It
  opens for anyone with the link -- a replay is what both players and any
  spectator already saw -- and is served the SPA shell, `noindex`. The board
  faces the reader's own seat when their guest holds one here, else the seat
  that played first, and the page turns the board around anyway. The table
  offers it from the match history and at game over. Board, steps and
  verdicts all come from `/record` and `/reviews`.
- `/poker`, `/go`, `/chess` and anything under them: 302 to `/` (the games
  that were removed).

## The landing API (`/papi`)

The landing pages read and write over JSON. Every response is the same
envelope: `{"ok": true, ...payload}`, or `{"ok": false, "error": {"code",
"message"}}` — including on a non-2xx status, so the client parses bodies
rather than leaning on the status. Requests go same-origin, so the guest
cookie rides along and identity needs nothing from the client; writes carry
the page's CSRF token in `x-csrf-token`.

```
GET  /papi/library                     {ok, games, coming_soon, guest_name}
GET  /papi/games/:slug                 {ok, game, formats, clock_presets, copy, guest_name}
POST /papi/games/:slug                 {format, name, clock, selections}
                                         -> {ok, id, path, player_id}
GET  /papi/games/:slug/rooms/:id       {ok, state, inviter_name, summary, disconnected}
POST /papi/games/:slug/rooms/:id       {name} | {player_id} -> {ok, id, path, player_id}
GET  /papi/games/:slug/rooms/:id/reviews  (open; a seat's visit -- the guest
                                       cookie against the seats -- is what queues
                                       an analysis that is owed)
                                       {ok, players, games: [{game_number,
                                           status, turns, review}]}
                                         review: {levels, timing_ms, players, turns}; a
                                         turn names its record lines (entry,
                                         double_entry, answer_entry) and each
                                         candidate move its position and landings
POST /papi/games/:slug/rooms/:id/reviews/retry  {game_number} -> as GET, a failed
                                         game queued again (a seat only)
GET  /papi/games/:slug/rooms/:id/record  (open)
                                       {ok, slug, id, you, seated, record}  (the game's
                                       `record`; `you` is the seat the board faces --
                                       the reader's own, else the first -- and `seated`
                                       says whether that seat is theirs)
GET  /papi/codes/:code                 {ok, slug, code}  (the code as typed, else
                                       normalised: the one that answered comes back)
GET  /papi/me/prefs                    {ok, prefs}
POST /papi/me/prefs                    {key, value} -> {ok, prefs}
```

`path` is the URL of the seat that was just taken (`/:slug/:id`, carrying
nothing): the client goes there, and the seat waits in the lobby until its
opponent arrives. The seat is held by the guest cookie the write came with,
so the same URL is what anyone would be given for that room. `state` is `open` (a free seat), `away` (a seat
whose player is gone), `full` (nothing to offer) or `missing` (the room is
over) — the same four cases the server used to decide for itself.

A game's own `clocks` are preset ids; `clock_presets` carries every preset,
so the picker can name the ones the game offers. Statuses: 404 `not_found`
(no such game, no such code, a room that is over), 422 `validation_failed`
(a name, a mode, a clock or a seat the room refused), 500 `server_error`.
Every decision behind these lives in `src/oskol/handlers/landing.gleam`,
except the record's, in `src/oskol/handlers/record.gleam`: it opens on the
room (the rooms cap `game`), and a lobby, a slug that is not the room's game
and a room that is gone all answer the same 404, as the game channel refuses
without saying which. The caller's guest (the cap `seated_game`, which
answers which seat a guest holds) is what picks the seat the board faces,
what queues an analysis the engine is owed, and what a retry takes.

`/papi/me/prefs` is the visitor's own display taste — today the backgammon
board's colours, under `backgammon_theme`. Gleam owns the whitelist
(`src/oskol/guests/prefs.gleam`): an unknown key or a value that names no
theme is a 422 and nothing is written. It is display only: a theme never
reaches a scene, an event or the game channel, and each player's board is
their own. The client also keeps the pick in `localStorage` (the `storePref`
port), which is what paints the board before the round trip and all a
visitor whose guest cookie is gone has.

## Post-game reviews (backgammon)

Every backgammon game is graded by the analysis engine once it is over,
each game of a match on its own: moves, cube decisions, luck, a PR per
player. The engine is a separate private Fly app (`oskol-analysis`, repo
`amilner42/oskol-analysis`, Aveline doc `bg-analysis-service`); nothing in a
game or a room talks to it.

- `backgammon/analysis` encodes Oskol's board to the engine's 26-int
  on-roll board and builds one entry per turn (cube relative to the mover,
  away scores, Crawford, dice, the played board). The turns come from
  replaying seed + log through `gamekit/replay`, which folds the typed
  twins of the calls the rehydrator makes, so a review sees exactly what
  the room saw. A double the engine thinks illegal (a dead cube) is folded
  away; a turn cut off by a resignation or a clock keeps only an answered
  double.
- When a step ends a game (`oskol/handlers/reviews.game_ended`), the room
  casts `Oskol.Reviews.Queue`; the queue runs `reviews.run` in a task, one
  room at a time, after the persister has flushed. A game already done or
  queued is not run again; a failure is stored and retried at most twice
  (30 s, then 2 min). The queue is in memory: after a restart, the first
  request for a game still owed a review queues it again -- a request from
  one of its own seats, since reading a review is open to anyone with the
  room and engine time is not. That is also how games finished before
  reviews existed get theirs: lazily, never by a migration.
- `game_reviews` holds one row per (game_id, game_number): status
  (`pending`, `done`, `failed`), attempts, the engine's response verbatim.
  `GET /papi/games/backgammon/rooms/:id/reviews` reshapes it for a page
  (`oskol/reviews/report`): per turn the grade, the move played, the best
  and the top five with equity lost, cube verdicts and luck; per player
  PR, error, grade and mistake counts and luck. A game with no review yet
  answers `pending` and is queued; the others are `done`, `failed`,
  `empty` (no complete turn) and `playing`.
- Config `:oskol, :analysis`: prod reads `ANALYSIS_URL` (default
  `http://oskol-analysis.flycast`) and connects over IPv6 (Fly's private
  network; `ANALYSIS_IPV6=false` turns it off). Dev defaults to
  `http://localhost:18082`, IPv4. To point dev at the real engine:
  `fly proxy 18082:80 oskol-analysis.flycast -a oskol-analysis` (stop it
  after), or run it locally in the oskol-analysis checkout:
  `.venv/bin/uvicorn app.main:app --port 18082`. Tests never hit the
  network: the queue is off (`config :oskol, Oskol.Reviews.Queue`) unless
  a test turns it on, and requests go to a `Req.Test` stub.

## Adding a game
Backgammon is the product and the only game registered, but the framework
still takes another one:
1. Create `src/<slug>/game.gleam` implementing `gamekit/game.Game`. Give
   `Info` its formats (with settings if the creator should tune anything),
   the clock presets it offers, and a `timeout` policy.
2. Register it in `src/gamekit/registry.gleam` (`all()`).
3. Add `test/<slug>/conformance_test.gleam` using `gamekit/conformance`
   (random playouts to termination, replay determinism, your invariants),
   then `mix oskol.fixtures` so the golden and Elm suites cover it.
4. Its settings show up on the create page. It needs an Elm view in
   `assets/src/Games/<Name>/View.elm`, dispatched by slug in
   `Page/Play.elm`; the view reads the protocol Scene, never new wire types
   (see `assets/src/Games/Backgammon/View.elm`). There is no generic
   renderer any more (it went with go); the repository history has one to
   start from.
5. Pick a slug that is not one of the removed games' (`poker`, `go`,
   `chess`): the router sends those home before any game route sees them.

## Development commands

```bash
bin/check             # everything below, in order; add --browser for the Playwright smokes
                      # (PORT picks the port it serves them on; 4400 by default)
mix deps.get          # Elixir + Gleam deps
mix compile           # compiles Gleam (via mix_gleam) and Elixir
bin/test-gleam        # Gleam unit, rules, oracle, property, hidden-info and golden tests
mix oskol.fixtures    # regenerate fixtures: `replays` (committed) and/or `payloads` (derived)
mix test              # Elixir room, bots, channel, LiveView tests
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null   # Elm typecheck
cd assets && ../node_modules/.bin/elm-test --compiler ../node_modules/.bin/elm  # Elm tests (needs `mix oskol.fixtures payloads`)
mix assets.build      # Elm (via esbuild plugin) + Tailwind
mix phx.server        # http://localhost:4400 (4000 belongs to other apps on this machine)
mix oskol.seed        # local backgammon rooms at codes 000001.. parked in positions worth
                      # testing (bar, bearing off, a dance, cube decisions), P1 and P2 seated
                      # but held by nobody, P1 to act; prints each room's invite link, and
                      # the browser that takes a seat from it holds it (lib/oskol/dev/seeds.ex);
                      # two players means two browsers (a private window will do);
                      # 000010 is a single game played to the end, with a review
                      # (start the fly proxy first, or the review fails and waits);
                      # 000011 a match to 3 played to the end: its replay is
                      # /backgammon/000011/replay
node playwright/test-backgammon-smoke/test.js   # backgammon: stage, undo, play, with a clock
node playwright/test-backgammon-dance/test.js   # backgammon: a danced turn (it arranges the
                                               # room itself), the roll animation, the delay
node playwright/test-backgammon-landscape/test.js  # backgammon on a sideways phone: the board
                                               # fits the screen height exactly, nothing scrolls
node playwright/test-backgammon-replay/test.js  # the replay of a finished match (it arranges
                                               # the room): steps, keys, swipes, analysis
                                               # pending -> done, retry, phones; the analysis
                                               # is stubbed unless REPLAY_REAL=1
node playwright/test-spa-landing/test.js        # the home board and CREATE GAME's dialog, old
                                               # links redirect, a full create -> play click-through
node playwright/review-pages/test.js            # screenshots of the home board, CREATE GAME,
                                               # the lobby and the theme picker (desktop + phone)
node playwright/review-games/test.js            # screenshots of games in play (desktop + phone)
```

CI (`.github/workflows/ci.yml`) runs the same steps as `bin/check --browser`,
smokes included (one job, one server, in `bin/check`'s order).

Notes:
- mix and the gleam CLI share `build/`. `mix compile` removes the
  `gleam@@compile.erl` escript gleam leaves behind (see
  `Mix.Tasks.Compile.GleamClean` in mix.exs), and `bin/test-gleam` clears our
  package's gleam build output so the gleam CLI recompiles it with beams after
  mix has touched it. Use `bin/test-gleam`, not bare `gleam test`.
- Elixir test support lives in `test_support/`, not `test/support/`, because
  gleam compiles any `.ex` it finds under `test/`. `test/oskol_test_files.erl`
  is the one Erlang file: file access for the golden tests.
- The gleam compile step forwards positional args to deps tasks. `mix test`
  is aliased to compile first and then run with `--no-compile` so
  `mix test path/to/file.exs` works; for scripts use
  `mix run -e 'Code.eval_file("path")'`.
- In this environment the Elm package cache is populated by git clone
  (GitHub zipballs are blocked); see `.claude/skills`.
- The pixel font (Press Start 2P) and the landing sans (IBM Plex Sans) are
  self-hosted under `priv/static/fonts`; nothing loads a font from a CDN.
- Playwright scripts take the browser from `PW_CHROMIUM` when set (`bin/check`
  falls back to a preinstalled Chromium under `/opt/pw-browsers`); CI runs
  `npx playwright install chromium` instead.

## Development workflow for Claude
- Work is tracked in Aveline, not here: `aveline -w oskol get-orientation`
  is the loop (ticket, branch, PR, adversarial review, CI, merge, deploy,
  worklog). This file is the code truth that loop points back to.
- Do not leave servers running. For a browser check, run the server and the
  Playwright script in one bounded foreground command, then stop it.
- Verify with `bin/check` before reporting.
- Keep game logic in Gleam. Keep UI state in Elm. Keep Elixir game-agnostic.
- Text rendering: `Oskol.GameKit.text(instance, player_id)` (or
  `gamekit/host.text`) shows a game as text with the legal actions, so you can
  play a game from a script without a browser.
- Rooms can be set up with a `seed:` (`Game.configure/2`) for reproducible
  games in tests and screenshots.

## Testing: one layer at a time, and the seams between them

Every game is its seed plus its action log, and the suite leans on that.

**Gleam (`bin/test-gleam`)**
- Rules in controlled positions: `test/backgammon/rules_test.gleam` and `cube_test.gleam`
  build boards to assert dice order, bar entry, bearing off, hits, gammons,
  doubling, Crawford, Jacoby, resigning.
- `test/backgammon/oracle_test.gleam`: an independent move generator,
  written from the rulebook on raw checker data, checked against
  `board.sequences` on hundreds of random boards (`positions.gleam` builds
  them) plus named positions with the expected sequences spelled out.
- `test/backgammon/properties_test.gleam`: staged-turn invariants over random
  positions (undo is an exact inverse, a legal first move never strands a
  die, pip accounting, commit) and a no-leak property over random games.
- Conformance (`test/backgammon/engine_test.gleam`): seeded playouts to
  game over with the game's invariants, replay determinism, malformed
  actions rejected. Random play excludes `resign` (`conformance.Options`).
- Golden replays (`test/gamekit/golden_test.gleam`): every file in
  `test/fixtures/replays` replays to its recorded fingerprint, and every
  registered format has one. A rules change fails here; when intended, run
  `mix oskol.fixtures replays` and read the diff.
- Framework units: rng, clocks (including the turn delay), action decoding
  and validation, `event.for_viewer`, host/protocol shapes.
- `test/backgammon/analysis_test.gleam`: the engine board in controlled
  positions, the cube and match state per turn, scripted logs (doubles,
  drops, resigns, timeouts, picked dice), and the property that every
  played board is legal for its dice under an independent generator on the
  engine's own format; `test/oskol/reviews_handler_test.gleam`: when a
  review is owed, retries, and the page's shape, on stub caps.

**Fixtures (`mix oskol.fixtures`)** come from `gamekit/fixture`: replays are
small and committed; payload captures (every update every viewer received
for the first steps of a playout) are derived, gitignored, and embedded in
`assets/tests/Fixtures.elm` for elm-test.

**Elm (`elm-test`)**
- `ProtocolTest`: every fixture payload decodes; cross-checks that hold for
  any game (viewer matches seat, spectators have no legal actions, select
  candidates exist in their zone, ids unique per zone, events only name
  tokens the viewer can see).
- `BackgammonViewTest`: the view on real scenes, pure update logic, and
  rendered DOM facts (30 checkers, sources marked only for legal moves,
  buttons follow the legal actions).
- `PlayUpdateTest`: fixture payloads replayed through `Page.Play.applyPayload`.
- `RouteTest`, `SessionTest`, `CatalogTest`: the client's routes round-trip,
  the boot flags, and the `/papi` envelope and decoders (which are lax about
  keys they do not need and strict about the ones they do).
- `GameLandingTest`: the home page on decoded responses — the board and its
  four menu entries, CREATE GAME's dialog (the mode, clock and twist
  dropdowns, their defaults, the summary, inline validation), the theme
  picker, and the invite's three answers.
- `ReplayTest`: the replay on the real record and analysis of seed 000011
  (`ReplayFixtures`): decoders, the board at every step, stepping, keys,
  swipes, game switching, and the analysis filling in without moving the
  viewer; polling only while something is pending.

**Elixir (`mix test`)**
- `test/oskol/room_test.exs`: `Oskol.Bots` (test_support) plays random
  legal actions through the room for every registered game and format,
  many rooms concurrently; disconnect, rejoin, rematch keeps the setup.
  Channel tests cover join replies, spectators, per-player payloads, and
  reconnects; `spa_controller_test.exs` covers what is still the server's on
  the two landing routes — the shell, the head a crawler reads, the 404 for a
  slug that names no game, the removed games' redirects, and the guest
  cookie and the name it remembers.

**Browser (`bin/check --browser`)**: Playwright smokes create real games and
play them; review scripts take screenshots for eyeballing. The ways into a
game live once, in `playwright/lib/flows.js`: `createGame` (`/` -> CREATE
GAME -> the dialog, by element id), `joinByLink`, `joinByCode` and
`openSeat`, and `seatedContext` for a browser that already holds a seat. A
smoke uses those rather than clicking through the home page itself, so a
change to the home page or the invite touches that one file. Two players
are two browser contexts: a seat is held by the browser's guest cookie, so
two pages of one context are one player.

When you add a rule, add a controlled-position test before the playouts:
the playouts prove nothing crashes, the position tests prove the rule is
right. A registered game's conformance test plus `mix oskol.fixtures` give
it golden replays and Elm contract coverage for free.

## Known patterns to avoid
- Don't add per-game code to Elixir or to `Protocol.elm`.
- Don't put animation or wizard state in a Gleam engine.
- Don't call system randomness in a game.
- Don't add emojis or files unless asked.

## Persistence

Games survive deploys and machine sleep. Every room writes behind (never
blocking play) to Postgres via `Oskol.Game.Persister`: a `games` row (code,
setup, seed, seats with the guest holding each, status, winners) and one `game_actions`
row per state-mutating step — player actions and clock expiries alike, each
with its millisecond offset from the instance's start. A lookup that finds no
live process replays seed + log through the same gamekit calls at those
offsets (timeline shifted to "now", so downtime charges nobody) and the room
carries on; the guest holding each seat round-trips, so every player's
browser still holds its seat. The
hour-idle shutdown is therefore graceful. Dev/test use local databases
(`oskol_dev`/`oskol_test`, created by `mix ecto.setup` / the `mix test`
alias); prod reads `DATABASE_URL` (Fly Managed Postgres via pgbouncer, so
postgrex runs with `prepare: :unnamed`) and migrates on boot. A room's raw
`control:` (tests only) does not persist; real rooms use clock preset ids,
which do.

Seats once carried a secret token in `games.players`; they carry the guest
id instead, and the data migration `DropSeatTokens` strips the dead key. A
row that still has one (a room live in another node at the time) rebuilds
fine: nothing reads it.

A rules change that makes old logs stop replaying needs those logs patched,
because a room is rebuilt from its log under today's rules. The one so far:
the between-games READY. `Oskol.Game.ReadyUpPatch` inserts the `ready`
steps old backgammon match logs lack (at the time of the game's end); the
data migration `PatchReadyUpLogs` ran it
once at boot, before any room could rehydrate, and `mix
oskol.patch_ready_up` / `Oskol.Release.patch_ready_up/1` show what it does
(dry run unless told to write).

Every visitor silently becomes a guest: `OskolWeb.Plugs.GuestId` mints an
opaque crypto-random id into a year-long HttpOnly cookie (renewed on every
visit) and mirrors it into the session, so LiveView mounts see it on the
static render. `Oskol.Guests` touches the guest's row on mount and remembers
the last display name they played under (last writer wins); that name
prefills the create and join forms, and each seat in `games.players` records
the guest id. The same row carries `prefs` (jsonb): display preferences that
follow the guest between browsers, written through `/papi/me/prefs` and
whitelisted in `src/oskol/guests/prefs.gleam`. The id is also the credential:
a seat is held by the guest that took it, the game channel attaches on it
(the socket reads it off the session that the websocket's own upgrade request
carried, which Phoenix hands over only against the page's `_csrf_token`), and
losing the cookie loses the seats it was holding — they can be claimed back
from the invite link, like anyone else's. `users` is a deliberately skeletal
placeholder (it ships empty) for the account-claim path via `guests.user_id`,
which is the point of holding a seat by the guest rather than by a token:
when a guest becomes a user the seats come with them.

## Future
- Twists as settings: a reroll in backgammon, and more after it.
- Bots derived from `legal` for solo play and balance reports.
