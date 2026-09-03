# Oskol - a library of two-player games

## Project Overview
Oskol (oskol.io) hosts small two-player games. **Tilt** is a head-to-head
poker roguelike: build poker hands, upgrade them in a shop, sabotage your
opponent, take their last life. **Backgammon** is the classic race game with
the doubling cube: single games, matches to 3, 5 or 7 with the Crawford rule,
or unlimited play with the Jacoby rule. Every game can be played with an
optional time control.

Games are built on **gamekit**, a small framework with one rule: adding a game
never touches the server or the client. A game is one Gleam module that
implements a five-function contract; everything else is generic.

**Tech stack:** Gleam (games + framework), Elixir/Phoenix (platform host),
Elm (client), Tailwind CSS.

## Architecture in one picture

```
Gleam games ──(five-function contract)──> gamekit host ──(opaque instance + JSON)──> Elixir room
                                                                                      │
Elm client <──(protocol: scene, legal, outcome, events)── Phoenix channel <───────────┘
```

Three layers, two fixed boundaries:

1. **Gleam owns games** (`src/gamekit/`, `src/tilt/`). Pure, seeded, tested.
2. **Elixir owns the platform** (`lib/`). Rooms, lobbies, reconnect, rematch,
   routes. It never sees a card or a piece: it calls `Oskol.GameKit`, which
   wraps `gamekit/host` and speaks only opaque instances and JSON.
3. **Elm owns the client** (`assets/src/`). One app decodes the fixed protocol
   and renders any game. Tilt has a bespoke view; other games get the generic
   renderer for free.

## The game contract (`src/gamekit/game.gleam`)

```gleam
Game(
  info:          Info,                                      // slug, name, formats, player counts
  init:          fn(Config, List(Seat), Rng) -> Result(state, String),
  decode_action: fn(action.Incoming) -> Result(action, String),
  apply:         fn(state, PlayerId, action) -> Result(#(state, List(Event)), String),
  legal:         fn(state, PlayerId) -> List(Schema),       // what this player may do now
  scene:         fn(state, Viewer) -> Scene,                // per-viewer projection
  outcome:       fn(state) -> Outcome,
  clocks:        fn(state) -> List(PlayerId),               // who is on the clock right now
)
```

Rules that keep this honest:
- **All randomness goes through `gamekit/rng`** stored in the state. Never
  `int.random` or `list.shuffle`. A game is its seed plus its action log.
- **`apply` validates and never mutates on error.** It returns events for
  every state change; the client animates from events, not from diffing.
- **No presentation in the engine.** No animation flags, no wizard state.
  Multi-step interactions are action schemas with candidates.
- **Ids are deterministic and opaque.** Checkers are `"w1".."b15"`, shop
  cards `"shop-<round>-<n>"`, Tilt cards `"<player>-c17"`: labels shuffled
  independently of the deck, so an id never reveals a face or a position.
  Faces travel as token props.
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
  be charged right now (both during simultaneous play, one on their turn, none
  during a reveal). `gamekit/clock` owns the arithmetic, `gamekit/instance`
  applies it with the host's `now`, and a player who runs out forfeits.

## The protocol (`src/gamekit/scene.gleam`, `event.gleam`, `action.gleam`)

The client only ever decodes these:
- **Scene**: `players` (counters, flags, data) and `zones` of `tokens` with
  stable ids, a `face`, and `props`; plus a narrow `data` escape hatch.
- **Events**: `token_moved`, `counter_changed`, `revealed`, `phase_changed`,
  `message`, or `custom(kind, payload)` for bespoke views.
- **Schemas**: legal actions as `{name, label, params}` where a `select` param
  carries its zone and candidate ids. Select params are arrays on the wire.
- **Outcome**: `ongoing` or `finished(winners)`.
- **Clock**: `enabled`, `label`, per-player `remaining_ms` and `running`,
  `timed_out`. Running clocks keep ticking on the client from the snapshot.

Actions in: `{"name": "play_hand", "params": {"cards": ["AS", "KD"]}}`.
Legal actions may be enumerated (backgammon sends one `move` schema per legal
move) or described with candidates (Tilt's `play_hand` selects from the hand).
Hidden information is resolved by the `scene` projection per viewer: in
backgammon the mover stages moves (`move`, `undo`) that only their own scene
shows, and commits them with `play`; the opponent and spectators see the
board as it stood when the turn began until then.
Schemas with nothing to choose become one-click buttons in the generic client.

### Time controls
Presets live in `gamekit/clock.presets()` (none, blitz, rapid, delay, per
move) and are offered in every lobby; both players must agree, and "none" is
the default so it never blocks a start. Fischer adds an increment after your
move, Bronstein gives free seconds at the start of each move, per-move resets
every turn. The Elixir room schedules a tick for the next possible expiry and
calls `GameKit.expire/2`.

## File map

```
src/gamekit/        framework: rng, scene, event, action, game, instance,
                    registry (add games here), host (Elixir surface),
                    text (agent/test rendering), conformance (generic checks)
src/tilt/           Tilt: state, engine (actions + events + legal), projection
                    (scene), game (contract), codec (JSON), poker/, shop/
src/backgammon/     Backgammon: board (rules + move generation), state (turns,
                    dice, cube, match play), engine, projection, game
test/gamekit/       protocol, rng, clock tests
test/tilt/          hand, score, engine, conformance (random playouts, replay)
test/backgammon/    board rules, engine, cube (take/drop, Crawford, Jacoby,
                    resign, unlimited), conformance (single games and matches)
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: lobby, formats, actions, rematch
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
lib/oskol_web/live/landing_live.ex       "/" library, "/:slug" start page + lobby (one LiveView,
                                         patch navigation between them)
lib/oskol_web/components/game_art.ex     per-game accent colour + poster illustration (optional)
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the Elm client
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Tilt/Adapter.elm  Scene -> Tilt's PlayerView
assets/src/Games/Backgammon/View.elm  bespoke backgammon board on the protocol Scene
assets/src/Generic/View.elm      fallback renderer for games without a bespoke UI
assets/src/View/Clock.elm        clock display shared by all renderers
assets/src/View/Game.elm         Tilt's bespoke UI
assets/css/app.css               the multicade/notebook design system (paper, pixel,
                                 pix, btn-arcade, tile, bg-board...) used by LiveView
                                 pages and the Elm game screens alike
```

## URLs
- `/` game library
- `/tilt` start a Tilt game; `/tilt?game=<id>` is the invite link
- `/tilt/<id>?name=<player>` a running game
- `/backgammon`, `/backgammon/<id>` the same for backgammon

## Adding a game
1. Create `src/<slug>/game.gleam` implementing `gamekit/game.Game`.
2. Register it in `src/gamekit/registry.gleam` (`all()`).
3. Add `test/<slug>/conformance_test.gleam` using `gamekit/conformance`
   (random playouts to termination, replay determinism, your invariants),
   then `mix oskol.fixtures` so the golden and Elm suites cover it.
4. It is now playable at `/<slug>` with the generic renderer. Add a bespoke Elm
   view only if you want one; it must read the protocol Scene, never new wire types
  (see `assets/src/Games/Backgammon/View.elm` for a small one).

## Development commands

```bash
bin/check             # everything below, in order; add --browser for the Playwright smokes
mix deps.get          # Elixir + Gleam deps
mix compile           # compiles Gleam (via mix_gleam) and Elixir
bin/test-gleam        # Gleam unit, rules, oracle, property, hidden-info and golden tests
mix oskol.fixtures    # regenerate fixtures: `replays` (committed) and/or `payloads` (derived)
mix test              # Elixir room, bots, channel, LiveView tests
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null   # Elm typecheck
cd assets && ../node_modules/.bin/elm-test --compiler ../node_modules/.bin/elm  # Elm tests (needs `mix oskol.fixtures payloads`)
mix assets.build      # Elm (via esbuild plugin) + Tailwind
mix phx.server        # http://localhost:4000
node playwright/test-tilt-smoke/test.js         # browser smoke test (server must be running)
node playwright/test-backgammon-smoke/test.js   # backgammon: stage, undo, play, with a clock
node playwright/review-pages/test.js            # screenshots of library, start pages, lobby (desktop + phone)
node playwright/review-games/test.js            # screenshots of both games in play (desktop + phone)
```

CI (`.github/workflows/ci.yml`) runs the same steps as `bin/check --browser`.

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
- The pixel font is self-hosted under `priv/static/fonts`.
- Playwright scripts take the browser from `PW_CHROMIUM` when set (`bin/check`
  falls back to a preinstalled Chromium under `/opt/pw-browsers`); CI runs
  `npx playwright install chromium` instead.

## Development workflow for Claude
- Do not leave servers running. For a browser check, run the server and the
  Playwright script in one bounded foreground command, then stop it.
- Verify with `mix compile`, `gleam test`, `mix test`, and the Elm typecheck
  before reporting.
- Keep game logic in Gleam. Keep UI state in Elm. Keep Elixir game-agnostic.
- Text rendering: `Oskol.GameKit.text(instance, player_id)` (or
  `gamekit/host.text`) shows a game as text with the legal actions, so you can
  play a game from a script without a browser.

## Testing: one layer at a time, and the seams between them

Every game is its seed plus its action log, and the suite leans on that.

**Gleam (`bin/test-gleam`)**
- Rules in controlled positions: `test/tilt/rules_test.gleam` sets exact
  hands and sabotage flags; `test/backgammon/rules_test.gleam` and
  `cube_test.gleam` build boards to assert dice order, bar entry, bearing
  off, hits, gammons, doubling, Crawford, Jacoby, resigning.
- `test/backgammon/oracle_test.gleam`: an independent move generator,
  written from the rulebook on raw checker data, checked against
  `board.sequences` on hundreds of random boards (`positions.gleam` builds
  them) plus named positions with the expected sequences spelled out.
- `test/backgammon/properties_test.gleam`: staged-turn invariants over random
  positions (undo is an exact inverse, a legal first move never strands a
  die, pip accounting, commit) and a no-leak property over random games
  (opponent and spectator scenes never change while moves are staged).
- `test/tilt/hidden_test.gleam`: what each viewer may see (draw order,
  scrambled faces, locked-in hands) in scenes and in events, over random
  games, using `conformance.walk` to observe every transition.
- Conformance (`test/tilt/conformance_test.gleam`,
  `test/backgammon/engine_test.gleam`): seeded playouts to game over with
  per-game invariants, replay determinism, malformed actions rejected.
  Random play excludes `resign` (`conformance.Options`).
- Golden replays (`test/gamekit/golden_test.gleam`): every file in
  `test/fixtures/replays` replays to its recorded fingerprint, and every
  registered format has one. A rules change fails here; when intended, run
  `mix oskol.fixtures replays` and read the diff.
- Framework units: rng, clocks, action decoding and validation,
  `event.for_viewer`, host/protocol shapes.

**Fixtures (`mix oskol.fixtures`)** come from `gamekit/fixture`: replays are
small and committed; payload captures (every update every viewer received
for the first steps of a playout) are derived, gitignored, and embedded in
`assets/tests/Fixtures.elm` for elm-test.

**Elm (`elm-test`)**
- `ProtocolTest`: every fixture payload decodes; cross-checks that hold for
  any game (viewer matches seat, spectators have no legal actions, select
  candidates exist in their zone, ids unique per zone, events only name
  tokens the viewer can see).
- `TiltAdapterTest`, `BackgammonViewTest`, `GenericViewTest`: adapters and
  views on real scenes, pure update logic, and rendered DOM facts
  (30 checkers, sources marked only for legal moves, PLAY iff `play` is
  legal, click sends the right message).
- `MainUpdateTest`: fixture payloads replayed through `Main.applyPayload`.

**Elixir (`mix test`)**
- `test/oskol/room_test.exs`: `Oskol.Bots` (test_support) plays random
  legal actions through the room for every registered game and format,
  many rooms concurrently; disconnect, rejoin, rematch keeps format and
  clock. Channel tests cover join replies, spectators, per-player payloads,
  and reconnects; LiveView tests the library and lobby.

**Browser (`bin/check --browser`)**: Playwright smokes create real games and
play them; review scripts take screenshots for eyeballing.

When you add a rule, add a controlled-position test before the playouts:
the playouts prove nothing crashes, the position tests prove the rule is
right. When you add a game, its conformance test plus `mix oskol.fixtures`
give it golden replays and Elm contract coverage for free.

## Known patterns to avoid
- Don't add per-game code to Elixir or to `Protocol.elm`.
- Don't put animation or wizard state in a Gleam engine.
- Don't call system randomness in a game.
- Don't add emojis or files unless asked.

## Future
- Optional cube rules: beavers, automatic doubles.
- Persist seed + event log per game for replay and crash recovery.
- Bots derived from `legal` for solo play and balance reports.
- Split-screen dev mode with a time scrubber over events.
