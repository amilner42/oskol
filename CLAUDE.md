# Oskol - a library of two-player games

## Project Overview
Oskol (oskol.io) hosts small two-player games. **Tilt** is a head-to-head
poker roguelike: build poker hands, upgrade them in a shop, sabotage your
opponent, take their last life. **Backgammon** is the classic race game with
match play. Every game can be played with an optional time control.

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
- **Ids are deterministic** (cards are `"AS"`, shop cards `"shop-<round>-<n>"`,
  checkers `"w1".."b15"`).
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
                    dice, match play), engine, projection, game
test/gamekit/       protocol, rng, clock tests
test/tilt/          hand, score, engine, conformance (random playouts, replay)
test/backgammon/    board rules, engine, conformance (single games and matches)
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: lobby, formats, actions, rematch
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
lib/oskol_web/live/landing_live.ex       "/" library, "/:slug" start page + lobby
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the Elm client
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Tilt/Adapter.elm  Scene -> Tilt's PlayerView
assets/src/Generic/View.elm      fallback renderer for games without a bespoke UI
                                 (backgammon uses it today)
assets/src/View/Clock.elm        clock display shared by both renderers
assets/src/View/Game.elm         Tilt's bespoke UI
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
   (random playouts to termination, replay determinism, your invariants).
4. It is now playable at `/<slug>` with the generic renderer. Add a bespoke Elm
   view only if you want one; it must read the protocol Scene, never new wire types.

## Development commands

```bash
mix deps.get          # Elixir + Gleam deps
mix compile           # compiles Gleam (via mix_gleam) and Elixir
bin/test-gleam        # Gleam unit + conformance tests (seeded playouts for every game)
mix test              # Elixir room, channel, LiveView tests
mix assets.build      # Elm (via esbuild plugin) + Tailwind
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null   # Elm typecheck
mix phx.server        # http://localhost:4000
node playwright/test-tilt-smoke/test.js         # browser smoke test (server must be running)
node playwright/test-backgammon-smoke/test.js   # backgammon on the generic renderer, with a clock
```

Notes:
- mix and the gleam CLI share `build/`. `mix compile` removes the
  `gleam@@compile.erl` escript gleam leaves behind (see
  `Mix.Tasks.Compile.GleamClean` in mix.exs), and `bin/test-gleam` clears our
  package's gleam build output so the gleam CLI recompiles it with beams after
  mix has touched it. Use `bin/test-gleam`, not bare `gleam test`.
- Elixir test support lives in `test_support/`, not `test/support/`, because
  gleam compiles any `.ex` it finds under `test/`.
- The gleam compile step forwards positional args to deps tasks. `mix test`
  is aliased to compile first and then run with `--no-compile` so
  `mix test path/to/file.exs` works; for scripts use
  `mix run -e 'Code.eval_file("path")'`.
- In this environment the Elm package cache is populated by git clone
  (GitHub zipballs are blocked); see `.claude/skills`.

## Development workflow for Claude
- Do not leave servers running. For a browser check, run the server and the
  Playwright script in one bounded foreground command, then stop it.
- Verify with `mix compile`, `gleam test`, `mix test`, and the Elm typecheck
  before reporting.
- Keep game logic in Gleam. Keep UI state in Elm. Keep Elixir game-agnostic.
- Text rendering: `Oskol.GameKit.text(instance, player_id)` (or
  `gamekit/host.text`) shows a game as text with the legal actions, so you can
  play a game from a script without a browser.

## Testing notes
- Gleam conformance (`test/tilt/conformance_test.gleam`,
  `test/backgammon/engine_test.gleam`): seeded random playouts to game over,
  replay reproduces the same scene JSON, illegal actions rejected, every
  action emits events, per-game invariants (unique card ids, full hands
  during play, 15 checkers per color, no mixed points).
- Rules tests use controlled positions: `test/tilt/rules_test.gleam` sets
  exact hands and sabotage flags to assert scores, ties, game over, and every
  shop card's effect; `test/backgammon/rules_test.gleam` builds boards to
  assert dice order, the larger-die rule, bar entry, bearing off, doubles,
  hits, gammons, match play, and pip arithmetic over random games.
- When you add a rule, add a controlled-position test for it before the
  playouts: the playouts prove nothing crashes, the position tests prove the
  rule is right.
- Elixir tests build rooms through `Oskol.GameFixtures` and drive real
  channels and LiveViews.

## Known patterns to avoid
- Don't add per-game code to Elixir or to `Protocol.elm`.
- Don't put animation or wizard state in a Gleam engine.
- Don't call system randomness in a game.
- Don't add emojis or files unless asked.

## Future
- A bespoke backgammon board view (it plays on the generic renderer today).
- Doubling cube for backgammon matches.
- Persist seed + event log per game for replay and crash recovery.
- Bots derived from `legal` for solo play and balance reports.
- Split-screen dev mode with a time scrubber over events.
