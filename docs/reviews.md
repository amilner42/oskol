# Post-game reviews (backgammon)

How a finished game is graded, stored and read back. The engine itself is the
Aveline doc `bg-analysis-service` (and `bgsage-gotchas`); the operator's
commands are in Aveline `runbooks`. The standing rule (Aveline `decisions`,
2026-09-16): no read path replays a log, and no read starts engine work.

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
  (30 s, then 2 min). **Reading never queues anything**: a game ending and
  an explicit retry from a seat are the only things that spend engine time,
  because a replay page open on a shared link must not be able to put the
  engine to work. The queue scans persisted `analysis_owed` markers at
  boot and every minute; a lost enqueue or crashed worker recovers without
  a reader or a restart. Recovery does not duplicate a running job or skip
  its retry delay. Attempts are charged before engine IO: a crash during
  that IO counts toward the same three-attempt budget. When recovery runs,
  an interrupted final attempt becomes a visible failure. A failed database
  scan logs and tries again. Task crashes, including those before charging
  an attempt, have their own in-memory per-room budget: wait one minute,
  then two, then suspend automatic recovery after
  the third consecutive crash, logging once. The durable owed marker stays;
  a fresh enqueue (game ending or explicit player retry) or queue restart
  reopens the room. While suspended its page may still say pending: the
  operator alert, not a reader, requests intervention. Other rooms continue,
  and a normal task result resets its crash streak.
- **A finished game's answer is written, not rebuilt.** Replaying a room's
  log on read costs seconds and most of a megabyte per call (it took
  production down twice). The two moments that already do the replay
  write what they produced: `game_records` (one row per finished game, its
  record entries) when a game ends, and `game_reviews.report` (the rendered
  analysis, exactly what the page reads) when the engine's answer lands.
  Nothing rewrites a row for a game that is over. A room with no rows yet
  builds once on its first read and writes its rows (self-healing). When the
  report's shape has to change for rows already written (e.g.
  `RerenderCubeReports`), a
  migration nulls `report` on the done rows and the same first-read path
  renders each afresh from the stored `response`, with no engine time.
- Record freshness follows completed-game work, not ordinary actions:
  `games.records_generation` remembers the `analysis_owed_at` marker the
  replay read before its log. Record rows and their exact checkpoint are
  stored atomically, and an older backfill cannot mark a newer completion
  settled or rewind its checkpoint. Legacy rows establish this marker once.
  Index/detail reads fetch record numbers only; moving checkers or playing
  turns in the next game does not cause a new backfill.
- **A turn is graded as it is played, into a cache the job reads.** A
  57-turn game is about a minute of waiting after the last move; spread over
  the game it is nothing, and only the last turn is left. When a step commits
  a turn the room casts it to `Oskol.Reviews.Grader` (after the broadcast,
  never before, and never on the step that ended the game -- the job grades
  that turn itself), which POSTs a one-turn `/backgammon/review` and stores
  the reply in `turn_grades`, keyed by the sha256 of the request body. The
  body is built once, in Gleam (`analysis.one_turn_request`), and crosses as
  text, so the job builds the same bytes again to find the answer: a grade is
  found by the question it answers and by nothing else.
  `reviews.run` keeps its shape -- replay, build the turns, then look each one
  up and ask the engine, in one request, only for the misses
  (`reviews.answer`, `report.assemble`). Every turn cached is no engine time;
  the engine down all game means every turn misses and it is a plain batch
  review: same body, same retries, same boot sweep. The assembled answer keeps the engine's shape (`report.parse`, the
  ratings SQL and the puzzle extractor read it unchanged) plus `assembled:
  true`; its `turns` are the engine's own objects verbatim and its `players`
  are worked out in Gleam (`report.totals_of`, the engine's `review_game`
  arithmetic, held to every stored answer the suite keeps in
  `test/oskol/report_test.gleam`). `game_reviews` is still written once, by
  the job, so a shared link cannot change its mind.
  **Nothing about a grade reaches a player.** The Grader answers nobody,
  messages no room and publishes nothing; the `grades` capability is in the
  queue job's context alone and every other context holds a stub that panics
  (`analysis.no_grades`), so a handler that reached for it would be a loud
  500. A game on the board is absent from `/reviews`, not pending. What makes
  the cache hit at all is that `analysis.committed`, off the state an action
  lands on, builds exactly the turn the end-of-game replay builds -- folding
  it over a seeded log equals `analysis.games` turn for turn, which
  `analysis_test` holds it to. The engine needs one field for this: an
  optional `index` on a `Turn`, since luck on the opening roll is measured
  differently and a lone turn would otherwise be graded as one. The engine
  answers under the index it was given and falls back to the turn's place in
  the request only when it was given none, which is what lets one request ask
  about a gappy set of misses. Anything standing in for the engine owes the
  same -- the Playwright setup scripts stub one -- because an answer filed
  under the wrong turn is a review of the wrong positions.
  Bounded, because a dropped turn is only a miss: 4 requests in flight, 100
  waiting (oldest dropped, the count logged), and a 60 s circuit after a
  failure so a sleeping desktop is not asked once a turn by every live room.
  Grades are dropped when the game's answer is written, and a sweep drops
  what a room nobody finished left behind after a week. An engine upgraded
  mid-game would leave half a review at each depth: the misses are asked for
  at the depth the grades were given at, and grades that disagree among
  themselves are all thrown away for one fresh batch.
- `game_reviews` holds one row per (game_id, game_number): status
  (`pending`, `done`, `failed`), attempts, the engine's response verbatim,
  the rendered `report`, and that game's `turns`. `report` is what
  `oskol/reviews/report.to_json` makes of the response: per turn the grade,
  the move played, the best and the top five with equity lost and each
  candidate's chances (win, gammon and backgammon, both ways), the cube
  verdict with its three equities and the chances it was judged on, luck,
  and the turn's **per-roll grid** (`rolls`: see below); per player PR, error,
  grade and mistake counts and luck. The
  engine grades the cube only where the mover could have doubled (not
  the Crawford game, not the other side's cube), but it grades "no
  double" on the opening roll too; the report drops that one, and guards
  the rest the same way, so a page never shows a verdict on a double
  that could not have been offered. The cube's `optimal` is the call
  read off its three equities (`puzzles.cube_call`: double iff
  `min(DT, DP) > ND`, take iff `DT <= DP`), never the engine's
  `optimal_action` label; a report rendered before that carries the
  label instead, and the page reads neither -- `Replay.cubeCall` works
  the call out from the equities, so old rows need no re-render. (On
  prod, 2026-10-02, the label and the equities agreed on all 1612 cube
  verdicts.) The read path never builds it -- `GET .../reviews` is the index
  alone (game number, status, turn count: a few hundred bytes, from a query
  that touches neither body), and `GET .../reviews/<n>` sends that one
  game's stored `report` verbatim. Statuses: `done`, `pending`, `failed`,
  `empty` (no complete turn).
- **Every turn carries its per-roll grid** (`rolls`, about 1 KB a turn): how
  each of the 21 distinct rolls fares from the board that turn began on, as
  cells -- each the roll's own cubeful equity (`src/oskol/analysis/rolls`, the
  same shape `POST /papi/analysis/rolls` answers -- `docs/api.md`). It is free: the engine
  computes it for the luck of the roll on every turn and used to throw it
  away, so `rolls: true` on the request keeps what was already in hand (a
  turn with no dice costs one 3-ply call). The grid is 3-ply where the
  verdict above it is 4-ply, and the page has to say so.
  `rolls` is `null` on every turn of every answer stored before this, and
  those cannot be backfilled -- `mix oskol.reviews.rebuild` re-queues the
  engine rather than re-rendering -- so the replay asks for such a turn's
  grid on demand instead (one press, 0.2 s, cached).
  **Adding the flag moved the turn-grade cache key**, which is the sha256 of
  the request body: every grade stored before the deploy is a miss and is
  asked again once, at the end of its game. A cache miss, not a loss.
- `GET .../record` is assembled the same way: the head (players, match
  length, opening position) from starting the room's game and asking nobody
  to play it, plus one `game_records` row per game. It reads the live room
  instead whenever there is one -- that is free, and it carries the game on
  the board, which nothing writes down until it ends. So a replay page on a
  settled cold room wakes no room and replays no log. A missing or stale
  record still uses the existing recovery path until it is settled.
- A **match PR** is the same rows read the other way round:
  `GET /papi/games/:slug/rooms/:id/ratings` answers one entry per seat —
  the plain mean, to one decimal, of that seat's PR in the games of *this
  room* the engine has graded (`src/oskol/handlers/ratings.gleam`, on the
  `analysis.ratings` cap, which selects only the stored response's player
  totals; `report.player_prs` reads their ratings). Seats come from the
  stored setup, so ratings never wake a room or read its action log.
  A game still pending, failed or
  unfinished counts for nothing, and a match with none graded shows no
  number. It is display only, and open like the record; the table prints
  it beside each name and asks again when a game ends.
- Beside it, a **career PR**: the same answer's `career` per seat, the
  account that owns it over every graded game it has played anywhere. It is
  the home page's own number, from the home page's own maths
  (`home.counted`, `home.window_pr`, decision-weighted, `home.career_cap`)
  over the `analysis.graded_for` cap, so the table, the replay and the home
  can never print two different careers for one person. Null for a seat no
  account owns — a guest is a browser, not a person — and under
  `home.min_career_games` (5). One query per *owned* seat, so at most two
  for a table, rows only: no room woken, no log replayed, no engine time.
  The table stacks it under the match PR in the player bar (and drops it
  below 390px, where it would cost the name three characters); the replay's
  overview puts it under each player's PR for the game.
- Config `:oskol, :analysis`: prod reads `ANALYSIS_URL` (default
  `http://oskol-analysis.flycast`) and connects over IPv6 (Fly's private
  network; `ANALYSIS_IPV6=false` turns it off). Dev defaults to
  `http://localhost:18082`, IPv4. To point dev at the real engine:
  `fly proxy 18082:80 oskol-analysis.flycast -a oskol-analysis` (stop it
  after), or run it locally in the oskol-analysis checkout:
  `.venv/bin/uvicorn app.main:app --port 18082`. Tests never hit the
  network: the queue and the per-turn grader are both off
  (`config :oskol, Oskol.Reviews.Queue` and `Oskol.Reviews.Grader`) unless a
  test turns them on, and requests go to a `Req.Test` stub.
