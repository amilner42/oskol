# Agent instructions

This file is loaded into every agent session (`CLAUDE.md` is a symlink to it),
so it holds only what every task needs: rules, commands and pointers. Detail
lives elsewhere -- see "Where the rest lives" at the bottom -- and stays there.

## Team knowledge lives in Aveline

Product docs, tickets, briefs, decisions, runbooks and the worklog for Oskol
live in the `oskol` Aveline workspace, not in this repo. Read and write them
through the `aveline` CLI (`aveline --help` lists every operation).

Start every session by running:

```
aveline -w oskol get-orientation
```

That doc explains how the workspace organizes its knowledge and the work loop
(ticket, branch `osk-<slug>` off main, PR, review, CI, merge, deploy,
worklog). Read it before touching any doc. Run `aveline contract` before your
first doc write: it shows every block type and edit op with a valid example.

New docs are born private and new views land in your personal bucket. Publish
deliberately: pass `--visibility workspace` on create-doc (or run
`set-doc-visibility` after) for anything the team should see, and
`--bucket team` on create-view for shared views. `aveline use-workspace oskol`
once makes `-w` unnecessary.

## What Oskol is

Oskol (oskol.io) is a backgammon site: play a friend from a link, or Sage
(the analysis engine playing live), with no account, phone-first, free; every
finished game is graded by the engine, the replay teaches from it, and every
mistake becomes a puzzle in the player's practice. Formats: a single game,
matches to 3-21 (cube, Crawford), unlimited (cube, Jacoby); optional clocks
with a 12 s free delay per turn. A seat is held by the browser's guest cookie,
or by the account that owns it; signing in (email link or six-digit code) is
offered after the value, never as a gate. Poker, go and chess were removed
(their URLs redirect to `/`). Stack: Gleam (games + platform decisions),
Elixir/Phoenix (thin IO host), Elm (the whole client), Tailwind CSS v4.

## Architecture

```
Gleam games ──(contract)──> gamekit host ──(opaque instance + JSON)──> Elixir room
                                                                          │
Elm client <──(protocol: scene, legal, outcome, events, clock)── Phoenix channel <──┘
```

Three layers, two fixed boundaries:

1. **Gleam owns the game** (`src/gamekit/`, `src/backgammon/`): pure, seeded,
   tested. A game is one module implementing `gamekit/game.Game`.
2. **Elixir owns the platform** (`lib/`): rooms, setup, reconnect, rematch,
   persistence, routes. It never sees a checker or a die: it calls
   `Oskol.GameKit` (the only Elixir -> Gleam bridge), which speaks only opaque
   instances and JSON.
3. **Elm owns the client** (`assets/src/`): one `Browser.application` owns
   every URL, decodes the fixed protocol and reads page data from `/papi`.
   Elixir serves the SPA shell with the head a crawler needs, nothing else.

**Platform decisions live in Gleam too** (`src/oskol/`). Phoenix (router,
plugs, controllers, GenServers) is thin; it calls
`handler(ctx, session, request)` in Gleam, which makes every decision and
performs IO only through `ctx.<domain>.<cap>(...)`, then Elixir writes the
JSON. `Ctx` (`src/oskol/core/ctx.gleam`) is a record of capability closures
built by `Oskol.Gleam.CtxBuilder.build/1`; each `src/oskol/caps/<d>.gleam` has
an Elixir twin `lib/oskol/gleam/caps/<d>.ex` and **they must agree on
constructor tag and field order** (a Gleam record is a tagged tuple). Caps
speak domain types, never Ecto structs or raw maps. A failure that is product
behaviour is a `Result` the handler turns into the player's sentence;
anything else raises and is a 500. Tests build a `Ctx` of stubs that panic
(`test/oskol/fakes.gleam`), so a handler reaching unarranged IO fails loudly.
Nothing that decides anything exists twice.

**The game contract's rules** (full contract and protocol:
`docs/architecture.md`):
- All randomness goes through `gamekit/rng`, stored in the state; never
  `int.random` or `list.shuffle`. A game is its seed plus its action log.
- `apply` validates and never mutates on error; it returns events for every
  change, and the client animates from events, not diffs.
- No presentation in the engine: no animation flags, no wizard state;
  multi-step interactions are action schemas with candidates.
- Ids are deterministic and opaque; faces travel as props. Hidden information
  is the projection's job (`scene` per viewer, `event.for_viewer`); `custom`
  event payloads are not filtered, so never put a secret in one.
- Sort before you serialise a dict keyed by a custom type (atom order differs
  between VMs, which breaks scene JSON and golden fingerprints).
- Games never read the time: `clocks(state)` says who is charged,
  `gamekit/clock` does the arithmetic, the host supplies `now`.

## Rules that bite

- **Keep game logic in Gleam, UI state in Elm, Elixir game-agnostic.** No
  per-game code in Elixir or `Protocol.elm`.
- **No read path replays a log or spends engine time.** What a finished game
  produced (record, review, puzzles) is written once and read back as rows;
  only a game ending, a seat's explicit retry and operator tasks ask the
  engine. A stored review or puzzle answer is never rewritten on read; a
  change of shape is a migration.
- **A seat's holder is one rule** (`src/oskol/rooms/seat.gleam`,
  `seat.holder`); every door asks it. No URL carries a secret.
- **retain** (amilner42/retain, our spaced-repetition library) is **pinned by
  commit, never a branch**, in `mix.exs`: a player's schedule must not move
  because someone pushed upstream. Its tables arrive through
  `Retain.Migration`, one Oskol migration per schema version
  (`priv/repo/migrations/*_add_retain_v<NN>.exs`, from
  `mix retain.gen.migration`: never edit one, add the next). The ladder is
  `config :retain, intervals: [1, 1, 3, 7, 21, 58, 145, 365]` (level 0 is a
  day, so a missed puzzle returns tomorrow). Gleam never sees retain: it is
  the `practice` cap, implemented in `lib/oskol/gleam/caps/practice.ex`
  (`caps/activity.ex`, `Oskol.Practice` and the dev seeds also read its rows;
  add no new callers). A change retain needs is a PR there and a new `ref:`
  here, not a fork.
- **UI**: phone first. Screenshots at 390 and 320 portrait and 844x390
  landscape before you say a page fits. **Nothing may move or wobble when a
  control changes** (fixed heights, reserved widths, menus that float);
  check frame by frame. Subtle micro-interactions, clean type and spacing.
- **CSS/JS**: Tailwind v4 with its import syntax in `assets/css/app.css`
  (`@import "tailwindcss" source(none);` plus `@source` lines; no
  `tailwind.config.js`) -- keep it. Never `@apply`; no daisyUI. Only the
  `app.js` and `app.css` bundles exist: import vendor code into them, never
  link external scripts or styles, never write inline `<script>` in
  templates. Fonts are self-hosted under `priv/static/fonts`.
- **Phoenix**: there are no LiveViews, no `CoreComponents`, no generated
  `<.input>`/`<.icon>`/flash/`Layouts.app`. `OskolWeb.Layouts` is only the
  root document shell and `head_title/1`. Templates are HEEx (`{...}` in
  attributes, `<%!-- --%>` comments, class lists as `[...]`). Router `scope`
  aliases prefix their routes, so do not add your own alias. HTTP is `Req`
  (never httpoison, tesla or httpc).
- **Elixir**: no index access on lists (`Enum.at`, pattern matching); bind the
  result of `if`/`case` rather than rebinding inside; one module per file; no
  map access on structs; no `String.to_atom/1` on user input; predicates end
  in `?` (`is_` is for guards); no new deps (date/time is in the standard
  library); `Task.async_stream(..., timeout: :infinity)` for concurrent work.
- **Elixir test support lives in `test_support/`**, not `test/support/`
  (gleam compiles any `.ex` under `test/`). Use `bin/test-gleam`, never bare
  `gleam test` (mix and gleam share `build/`).
- **Servers**: 4400 is the human's server on the main checkout: never start or
  kill anything on it. Use your own port (`PORT=4407 mix phx.server`) and,
  for operator tasks on seeded rooms, your own database
  (`OSKOL_DEV_DATABASE=...`). Kill by port (`lsof -ti tcp:4407 | xargs kill`),
  never by name. Do not leave servers running: run the server and a
  Playwright script in one bounded foreground command, then stop it.
- **Tests**: rules come from the rulebook, never from the code. A new rule
  gets a controlled-position test before the playouts. Keep the suite fast:
  a test that is waiting is tagged `@tag :slow`, a test that is working runs
  in parallel.
- No emojis, and no new files unless the task needs them.

## Commands

```bash
bin/check              # while you work (~2 min): compile, Gleam, Elm, Elixir, formatters; no `slow` tests
bin/check --all        # plus the slow tests (~3.5 min); what CI's suite job runs
bin/check --browser    # --all, then the Playwright smokes on a server it starts (PORT, default 4400: pass another)
mix precommit          # compile --warning-as-errors, unlock unused deps, format, test, dependency audits
bin/test-gleam         # Gleam tests, one worker per core
mix test [path]        # Elixir tests minus `slow` (--include slow for all); bin/test-par [N] partitions them
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null          # Elm typecheck
cd assets && ../node_modules/.bin/elm-test --compiler ../node_modules/.bin/elm      # Elm tests (needs `mix oskol.fixtures payloads`)
mix oskol.fixtures     # regenerate `replays` (committed; read the diff) and/or `payloads` (derived)
mix assets.build && PORT=4407 mix phx.server   # a dev server on your own port
mix oskol.seed         # rooms 000001.. in positions worth testing (see Aveline runbooks)
```

Operator tasks (each a dry run unless `--write`; release twins in
`Oskol.Release`): `mix oskol.decks.build`, `mix oskol.puzzles.backfill`,
`mix oskol.puzzles.sync`, `mix oskol.puzzles.reposition`,
`mix oskol.reviews.rebuild`, `mix oskol.patch_ready_up`, `mix oskol.analyse`
(see Aveline runbooks before running one against prod). For a script:
`mix run -e 'Code.eval_file("path")'`. To play a game without a browser:
`Oskol.GameKit.text(instance, player_id)`; for reproducible rooms,
`Oskol.Game.configure(id, %{seed: ...})`. Dev talks to the engine on
`localhost:18082` (the fly proxy or a local uvicorn; Aveline runbooks).
Dev mail is at `/dev/mailbox`. Deploys are `bin/deploy` from main, never raw
`fly deploy`. Playwright scripts: `docs/testing.md`.

## Where things are

```
src/gamekit/          the framework: rng, scene, event, action, game, clock, instance, replay, registry, host
src/backgammon/       the game: board (rules, move generation), state, engine, projection, game, analysis, bot (Sage)
src/oskol/            platform decisions: core (ctx, session, error), caps, handlers/*, rooms, guests,
                      reviews, puzzles, practice
lib/oskol/            Elixir: game_kit.ex (the bridge), game/ (GameServer, Persister, Rehydrator, Bot),
                      reviews/ (Queue, Grader), puzzles/, auth, mail, gleam/ (CtxBuilder, caps/*.ex)
lib/oskol_web/        router, plugs (GuestId, PuzzlePicture), controllers (SPA shell, /papi), game channel
assets/src/           Elm: Main.elm (routes, shell, runs), Page/*, Api/*, Ui/*, Games/Backgammon/*, Protocol.elm
assets/css/app.css    the design system and the twelve board themes (.bg-theme-*)
test/                 Gleam tests (test/gamekit, test/backgammon, test/oskol) and Elixir *_test.exs
test_support/         Elixir test helpers; playwright/ browser smokes and screenshot tours
```

## Where the rest lives

**In the repo, `docs/`** -- code-adjacent reference that changes in the same
PR as the code it describes (update it when you change what it says):

| File | What |
|---|---|
| `docs/architecture.md` | the product in brief, the game contract and protocol, time controls, the Ctx/caps pattern, adding a game |
| `docs/api.md` | every URL and the `/papi` endpoint reference |
| `docs/identity.md` | guests, seats, accounts, the sign-in stamp, usernames, rate limits, mail |
| `docs/rooms.md` | the bot (Sage), persistence and rehydrate, ending a room, `games.state`, patching old logs |
| `docs/home.md` | the signed-in home's data: `/papi/me/home`, ratings, streak, recent rooms |
| `docs/reviews.md` | post-game reviews, the per-turn grader, records, match and career PR |
| `docs/puzzles.md` | puzzles, grading, the deck and its sync, practice sessions, sharing, pictures, universal sets |
| `docs/testing.md` | what each suite covers, fixtures, every Playwright script, CI, build notes |
| `docs/file-map.md` | the file-by-file map |

**In Aveline** -- product, decisions and operations: `overview`, `decisions`
(standing calls and their why), `backgammon` (rules, the table, the replay,
playing Sage), `pages` (what each page shows a player), `puzzles-brief`,
`home-brief`, `runbooks` (ports, seeds, the engine, prod, deploys),
`bg-analysis-service` and `bgsage-gotchas` (the engine), `worklog`.
