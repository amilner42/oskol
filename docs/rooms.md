# Rooms: the bot, persistence, ending a room, `games.state`

A room is `Oskol.Game.GameServer` (generic, game-agnostic); its seats and who
holds them are in [identity.md](identity.md).

## Playing the bot (Sage)

`opponent: "bot"` seats the creator and then Sage
(`rooms.seat_bot` -> `GameServer.join_bot`), which fills the table and starts
the game through the same `do_start` a second browser would. The name is
`rooms/name.bot_name`, and a creator called Sage is refused in one sentence:
the room refuses a name already at the table, so the bot could not sit down
beside them. The clock is forced to `none` whatever was sent -- the bot would
lose on time for its engine being slow, and a clock on one side of a table
needs per-seat controls gamekit has no idea about.

Who drives it: the room, after every state change and after a rehydrate,
starts one supervised task per bot seat whose turn it is with no think in
flight (`Oskol.Game.Bot`, under `Oskol.Game.BotSupervisor`). The task asks
the game (`GameKit.think/4`) and applies each action, paced (below), as an
ordinary player action; the room never waits on the engine, which takes
seconds. A
think that comes back empty is tried again at 5 s, 20 s and then every 60 s
(`config :oskol, :bot`), up to `stop_trying_after` asks -- about half an hour,
and the room goes idle before that anyway. **Sage never resigns for want of an
engine**: an engine we cannot reach is our problem, not a position, and a
resignation is a *result* (points, a rating, a review, all written down),
whereas a board that has not moved is recovered by the engine coming back.
So the game waits and the platform keeps asking (decision and history:
Aveline `decisions`, ticket `bg-bot-never-resigns`). A stale think is harmless:
`apply` refuses what is no longer legal and the next broadcast thinks again.
A think that played nothing while the game stood still is a bug, not a turn,
so that seat is left alone until the game moves rather than asked again at
once. A rematch counts a bot seat as already ready, so one REMATCH is enough.

The brain is `src/backgammon/bot.gleam`, pure, on `backgammon/analysis`.
Every ask goes to `POST /backgammon/review` with a single turn -- not to
`/moves` and `/cube`, whose board validator rejects a positive `board[0]`
and so 422s every position with an opposing checker on the bar. Rolling: the
cube is asked about only where `engine_can_double` says the engine would
grade one; doubled, `should_take` from the doubler's side answers. Moving:
the best play's board is found among `board.sequences`, emitted as
`move`s and a `play`; a dance is a `play`. Between games, `ready`, with no
engine. A resignation offered to it is accepted when the stakes are at least
`board.win_kind` as the board stands. It never resigns of its own accord and
never takes a move back. The suite's engine is the pure Gleam fake
`bot.fake_answer`, behind a `Req.Test` stub on the Elixir side, so both
layers play the same opponent and nothing touches the network.

At the table the player bar shows Sage with a chip badge (`Ui.Identity`) and
its presence dot pulses while a think is in flight -- the wire's
`players[].bot` and `players[].thinking`. Reviews, ratings and puzzles need
nothing: the bot's moves are ordinary logged actions.

**Pacing.** At 3-ply Sage answered before its own dice had landed on the
screen, so the task plays its turn at a pace a watcher can follow, on the
server, where every browser and spectator sees the same rhythm. The game's
`bot` answer carries a pace per action (`gamekit/game.Pace`): `Settle` for
something set in motion the next action waits on (the roll), `Beat` for a
decision to be seen coming (double, take, drop, an answer to a
resignation), `Step` for everything else (`move`, `undo`, `play`, `ready`).
Elixir never matches an action's name; it turns paces into milliseconds
with three knobs in `config :oskol, :bot` -- `settle_ms` 1600 (the tumble is
0.95 s, a double's earned dice land at 1.2 s, then a moment to read them),
`gap_ms` 400 between consecutive bot actions, `beat_ms` 800 from the change
that prompted a `Beat` -- all 0 in test. A turn is one task from the roll to
the play (decide, play, and while the turn is still the bot's and nobody else
has moved, decide again), so the move decision is thought about while the
dice are in the air and the dot stays lit throughout. Staging is the mover's
alone (`backgammon/projection`), so the person sees the dice land, the dot
pulse, then the play land whole when Sage commits: about 2.4 s after the
throw for two checkers, 3.2 s for a double's four, or later if the think is
slower. All of it stays well inside the 12 s free delay (asserted in
`bot_room_test.exs`). Pacing never outlives its position: each action goes
to the room process that started the think, by pid, and only if the room's
step count is still the bot's own last one (`GameServer.bot_action/4`); a
resignation, a timeout, the other player or a rehydrate moves it on and the
rest is dropped, not refused. The waits are a `receive` on a monitor of the
room in the task, never a sleep in the room, so a room that stops wakes the
task at once.

## Persistence

Games survive deploys and machine sleep. Every room writes behind (never
blocking play) to Postgres via `Oskol.Game.Persister`: a `games` row (code,
setup, seed, seats with the guest holding each, status, winners, and
`state`: where the game stands as of its last step) and one `game_actions`
row per state-mutating step — player actions and clock expiries alike, each
with its millisecond offset from the instance's start. A lookup that finds no
live process replays seed + log through the same gamekit calls at those
offsets (timeline shifted to "now", so downtime charges nobody) and the room
carries on; the guest holding each seat round-trips, so every player's
browser still holds its seat. The
hour-idle shutdown is therefore graceful.

## Ending a room

**A room that will not end itself is ended by a player.** Nothing prunes
rooms, so a lobby a friend never opens and an unlimited session nobody
presses NEXT in both sit in LIVE GAMES for ever. Two ways out, and they
are different shutdowns because a waiting room has no instance and a
between-games room has one:

- **A lobby** is closed from outside the game -- there is no game in it --
  by `POST /papi/games/:slug/rooms/:id/close` (the × on its LIVE GAMES row,
  `Ui.LiveGames`; END THIS GAME on the lobby page). `handlers/rooms.close`
  reads the row first (`persistence.room`), because a lookup rehydrates and
  a stranger's press must never be what rebuilds somebody else's room; a
  room that is already live is asked directly, since that wakes nothing and
  its memory is newer than the write-behind row. `GameServer.close/3` is the
  authoritative check -- the holder rule, and no game started -- and then
  writes and stops. The row takes its **own status, `closed`**: no game was
  played, so it is not `finished` and belongs in no recent list, no rating
  and no replay; `seated_rooms` lists `waiting` and `playing`, and
  `Oskol.Game.Rehydrator` refuses a closed row, so the code opens nothing
  ever again and the invite link says the game is gone. A second press, or a
  retry of a request that timed out after the write landed, is the same yes.
- **An unlimited session** is ended from inside, by the game: `close` is a
  backgammon action, legal between games and only in unlimited play
  (`state.can_close`; a match to a target ends when somebody reaches it, and
  a game in play is left by resigning). Either player, alone -- the
  alternative is one of them never pressing NEXT, which strands the room
  anyway. The score stands and whoever is ahead has won; level on points is
  `Finished([])`, which is why `state.Phase.Finished` carries an
  `Option(Color)`. Because it is an action it is a step in the log, so a
  room rebuilt from that log comes back over rather than offering NEXT, and
  `persist_finish` writes `finished` with `games.winners` exactly as a
  match's last game does -- the home's recent list needs no new shape. The
  table draws it from the legal actions like every other button
  (`bg-action-close`, END beside NEXT): the client never reads a format.
  Closing changes nothing about analysis: every game was graded as it ended.
  One consequence worth knowing: between the games of unlimited play both
  seats now have a legal action (`close`), so the snapshot's `to_act` --
  and LIVE GAMES' "Your move" -- names a player who has already pressed
  NEXT. That is true: the room is waiting on them to do something.

## `games.state`

**`games.state` mirrors the game.** With every step the room also writes
`gamekit/host.summary_json`: `to_act` (whose turn it is by the game's own
account, `Game.clocks` with or without a clock set: the mover, never
"anyone with a legal action", since a waiting backgammon player may always
resign), `on_clock` (whose clock is actually running), `outcome`, `phase`
the spectator scene's per-player counters and flags (score, pips,
to_move...), each seat's `clocks` as of that step, and `at`, the wall-clock
moment the clocks were read (added Elixir-side), which is what a reader
charges a running clock from: the row's `updated_at` moves for a seat
claim and not for a wake. It is game-agnostic and carries nothing hidden. It is what
lets active games be listed and watched from the database without waking
a room; a row from before it existed is null until its room next
rehydrates, which writes it. It is a snapshot, not a source: the log is
still what a room is rebuilt from.

## Databases, and old logs

Dev/test use local databases
(`oskol_dev`/`oskol_test`, created by `mix ecto.setup` / the `mix test`
alias); prod reads `DATABASE_URL` (Fly Managed Postgres via pgbouncer, so
postgrex runs with `prepare: :unnamed`) and migrates on boot. A room's raw
`control:` (tests only) does not persist; real rooms use clock ids (a preset, or a
tier the room's format sizes when it starts), which do.

Seats carry the guest id, not a secret token (the data migration
`DropSeatTokens` stripped the old key; a row that still has one rebuilds
fine, nothing reads it).

A rules change that makes old logs stop replaying needs those logs patched,
because a room is rebuilt from its log under today's rules. Example: the
between-games READY. `Oskol.Game.ReadyUpPatch` inserts the `ready`
steps old backgammon match logs lack (at the time of the game's end); the
data migration `PatchReadyUpLogs` ran it
once at boot, before any room could rehydrate, and `mix
oskol.patch_ready_up` / `Oskol.Release.patch_ready_up/1` show what it does
(dry run unless told to write).
