# The signed-in home (`GET /papi/me/home`)

The data rules behind `/` for an account (`Page.Home`). What the page shows
is in the Aveline doc `pages`; decisions in `src/oskol/handlers/home.gleam`.

A signed-in player has games waiting, a rating and a deck; the guest home
(OSKOL, a board and one sentence) shows none of it. `GET /papi/me/home` is the
whole signed-in home in **one** answer, and every part of it comes from
rows: nothing wakes a room, replays a log or spends engine time. A guest
gets `{ok: true, signed_in: false}` and keeps the home they have.

```
{ok, signed_in: true,
 live:     [ /papi/me/games' entries, unchanged ],
 form:     {games, recent, career, streak, sentence,
            series: [{game_id, game_number, pr, error, decisions, ended_at}]},
 practice: {due, deck, ladder: [n0..n7], days: [30 bools],
            today: {done}, patched_level, lead,
            severity: [{grade, total, in_progress, patched, due, new_left}]},
 recent:   [{id, slug, format, opponent, score: {yours, theirs},
             over, won: bool|null, pr, decisions, ended_at, path,
             games: [{game_number, path, result: {won, points, kind} | null,
                      pr, decisions, ended_at}]}],
 more, next}
```

The page draws them in that order too: form (the two hooks, how you are
playing and how long you have kept showing up), then live games, practice
and recent matches.

- **A rating is decision-weighted.** A window's PR is the equity lost
  across its games over the decisions it was lost over, times 500 — the
  engine's own definition of one game's PR, applied to several, so a
  nine-decision game does not weigh like an eighty-nine-decision one.
  `recent` is the newest 20, `career` all of them (bounded at
  `home.career_cap`), one decimal, `null` under 3 graded games; the
  number printed beside a name at a table waits for 5
  (`home.min_career_games`). `sentence` is the same two numbers in words,
  because lower is better and a figure alone does not say so.
- **Only graded games count**, like the match PR: pending, failed and
  unfinished games are worth nothing — and so is a stored answer that
  carries a rating but not the totals behind it, which counts for nothing
  rather than as a flawless game.
- `series` is **oldest first** (the order the line is drawn), capped at
  `home.series_cap`; every other list is newest first. `error` and
  `decisions` ride along so the client can draw the rolling window exactly
  rather than re-deriving it from a rounded PR.
- **A recent entry is a room, not a game.** A match to 7 is one line --
  the format in the game's own words ("Match to 7", "Unlimited", "Single
  game", from the registry as `landing.invite_head` reads it), the score
  from this player's side, the rating over the whole match, the date --
  that opens in place to list its games; a single-game room is a line
  that opens its replay. The score is added up from the graded games'
  result lines, so a half-graded room shows the half it knows; **who won
  comes from the room's own `winners` row**, never from that score, or a
  match whose last game is not graded yet would be handed to the wrong
  player. A room's PR is decision-weighted like every other window here,
  so it is *not* the mean of its games' PRs. Paging counts rooms, so no
  page boundary can fall inside a match.
- **`streak`** is consecutive local days this account was active -- a
  puzzle answered **or** a game of theirs that finished -- by Retain's own
  rule (`Retain.streak`): today counts as soon as they are active and
  until then the streak is yesterday's, so it never reads 0 all morning; a
  whole day missed ends it. The two sources are unioned in one cap
  (`activity.days`, `lib/oskol/gleam/caps/activity.ex`): Retain's reviews
  for the puzzles and `game_records` for the games, in the deck's own
  timezone. `game_records` and not `game_reviews`, so a game the engine
  never answered for still counts as a day someone played. The run itself
  is counted in Gleam (`home.days_running`), bounded by
  `home.streak_window`. 0 is drawn as nothing, never as a zero.
- **Two queries over the same rows**, counted two ways: `analysis.graded_for`
  (`Oskol.Reviews.graded_for/2`) for the form, in games, because a rating
  is made of games; `analysis.graded_rooms_for`
  (`Oskol.Reviews.graded_rooms_for/3`) for the recent list, in rooms. Both
  join the review rows to the seats an account owns through the
  `games_players_gin` containment and project each answer down to the
  seats' totals in the database, as `rating_summaries` does. Reaching into
  a stored answer is the expensive half of both (it decompresses whole to
  give up two numbers), so the form's query asks for nothing it does not
  rate -- no opponent, no record line -- which is what pays for the second
  one. `recent`'s first ten rooms ride in the home answer; the rest come
  ten at a time from `/papi/me/games/graded?before=`, whose cursor is
  `<ended_at_ms>:<room_id>` and is compared as one row against the same
  two expressions the rooms are ordered on, truncated to the millisecond
  on both sides. A cursor only narrows what the caller already reaches:
  the account is the session's, never the cursor's.
- `practice` is the deck as the practice home reads it (`due`, `deck`)
  plus the pictures Retain does not answer on its own and the cap reads
  off its rows: `ladder`, the mistakes at each of the eight levels;
  `days`, whether the deck was practised on each of the last 30 local
  days (an attempt counts, a deferral does not); `today: {done}`, a plain
  count of the day's answers; and `severity`, the mistakes by band in
  three states -- untouched, in progress, patched -- with what each band
  still has to do today, plus `lead`, the tier to put in front. The page
  draws the same one-tier card the hub does (`Ui.Tiers`): the mark, "31
  left to fix", "23 patched", the bar -- highlighter yellow for what is
  in progress, the best move's green for what is patched -- and FIX ONE,
  with the other tiers as quiet rows and "3 fixed today" under it, and
  nothing else: `ladder` and `days` are still sent but no longer drawn.
- Decisions: `src/oskol/handlers/home.gleam`. Reading never creates a
  deck, and never queues a review.
