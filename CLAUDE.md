# Oskol - a library of two-player games

## Project Overview
Oskol (oskol.io) hosts small two-player games. The first is **Tilt**, a
head-to-head poker roguelike: build poker hands, upgrade them in a shop,
sabotage your opponent, take their last life.

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
)
```

Rules that keep this honest:
- **All randomness goes through `gamekit/rng`** stored in the state. Never
  `int.random` or `list.shuffle`. A game is its seed plus its action log.
- **`apply` validates and never mutates on error.** It returns events for
  every state change; the client animates from events, not from diffing.
- **No presentation in the engine.** No animation flags, no wizard state.
  Multi-step interactions are action schemas with candidates.
- **Ids are deterministic** (cards are `"AS"`, shop cards `"shop-<round>-<n>"`).

## The protocol (`src/gamekit/scene.gleam`, `event.gleam`, `action.gleam`)

The client only ever decodes these:
- **Scene**: `players` (counters, flags, data) and `zones` of `tokens` with
  stable ids, a `face`, and `props`; plus a narrow `data` escape hatch.
- **Events**: `token_moved`, `counter_changed`, `revealed`, `phase_changed`,
  `message`, or `custom(kind, payload)` for bespoke views.
- **Schemas**: legal actions as `{name, label, params}` where a `select` param
  carries its zone and candidate ids. Select params are arrays on the wire.
- **Outcome**: `ongoing` or `finished(winners)`.

Actions in: `{"name": "play_hand", "params": {"cards": ["AS", "KD"]}}`.

## File map

```
src/gamekit/        framework: rng, scene, event, action, game, instance,
                    registry (add games here), host (Elixir surface),
                    text (agent/test rendering), conformance (generic checks)
src/tilt/           Tilt: state, engine (actions + events + legal), projection
                    (scene), game (contract), codec (JSON), poker/, shop/
test/gamekit/       protocol + rng tests
test/tilt/          hand, score, engine, conformance (random playouts, replay)
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: lobby, formats, actions, rematch
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
lib/oskol_web/live/landing_live.ex       "/" library, "/:slug" start page + lobby
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the Elm client
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Tilt/Adapter.elm  Scene -> Tilt's PlayerView
assets/src/Generic/View.elm      fallback renderer for games without a bespoke UI
assets/src/View/Game.elm         Tilt's bespoke UI
```

## URLs
- `/` game library
- `/tilt` start a Tilt game; `/tilt?game=<id>` is the invite link
- `/tilt/<id>?name=<player>` a running game

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
bin/test-gleam        # Gleam unit + conformance tests (57 tests, seeded playouts)
mix test              # Elixir room, channel, LiveView tests
mix assets.build      # Elm (via esbuild plugin) + Tailwind
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null   # Elm typecheck
mix phx.server        # http://localhost:4000
node playwright/test-tilt-smoke/test.js   # browser smoke test (server must be running)
```

Notes:
- mix and the gleam CLI share `build/`. `mix compile` removes the
  `gleam@@compile.erl` escript gleam leaves behind (see
  `Mix.Tasks.Compile.GleamClean` in mix.exs), and `bin/test-gleam` clears our
  package's gleam build output so the gleam CLI recompiles it with beams after
  mix has touched it. Use `bin/test-gleam`, not bare `gleam test`.
- Elixir test support lives in `test_support/`, not `test/support/`, because
  gleam compiles any `.ex` it finds under `test/`.
- `mix run path/to/script.exs` trips over positional args in this setup; use
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
- Gleam conformance (`test/tilt/conformance_test.gleam`): 30 seeded random
  playouts to game over, replay reproduces the same scene JSON, illegal
  actions rejected, every action emits events, card ids stay unique.
- Elixir tests build rooms through `Oskol.GameFixtures` and drive real
  channels and LiveViews.

## Known patterns to avoid
- Don't add per-game code to Elixir or to `Protocol.elm`.
- Don't put animation or wizard state in a Gleam engine.
- Don't call system randomness in a game.
- Don't add emojis or files unless asked.

## Future
- Backgammon as game two (dice, tracks, alternating turns; generic renderer first).
- Persist seed + event log per game for replay and crash recovery.
- Bots derived from `legal` for solo play and balance reports.
- Split-screen dev mode with a time scrubber over events.
