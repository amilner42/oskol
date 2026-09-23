/**
 * The replay's analysis, answered in the browser: `/reviews` (the index: a
 * status and a turn count per game), `/reviews/<n>` (one game's analysis)
 * and the retry, every verdict built from the room's own record so each
 * names a real line of it. The replay smoke and the replay's review script
 * both stub with this rather than waiting on the engine.
 */
const GRADES = ['best', 'ok', 'doubtful', 'bad', 'very_bad', 'best', 'best'];

/** A review of one game built from its record: every turn graded, a best
 * move that leaves the previous position (so it visibly differs), every
 * double and answer judged. */
function reviewOf(record, game) {
  const seat = (id) => record.players.findIndex((p) => p.id === id);
  const color = (id) => record.players[seat(id)].color;
  const turns = [];
  let before = record.start;
  let n = 0;
  game.entries.forEach((e, i) => {
    if (e.kind === 'turn') {
      n += 1;
      const grade = GRADES[n % GRADES.length];
      const lost = { best: 0, ok: 0.012, doubtful: 0.045, bad: 0.11, very_bad: 0.31 }[grade];
      const side = (pos) => ({ white: pos.white, black: pos.black });
      const played = {
        rank: grade === 'best' ? 1 : 2, notation: e.moves.join(' ') || '(no play)', equity: 0.1 - lost,
        equity_lost: lost, played: true, position: side(e.position), landed: e.landed,
      };
      const best = {
        rank: 1, notation: grade === 'best' ? played.notation : '13/7 8/7', equity: 0.1, equity_lost: 0,
        played: grade === 'best', position: grade === 'best' ? side(e.position) : side(before), landed: [7, 7],
      };
      turns.push({
        number: turns.length + 1, log_index: 0, entry: i, double_entry: null, answer_entry: null,
        seat: seat(e.player), player_id: e.player, color: color(e.player), dice: e.dice, double: null,
        move: e.moves.length === 0 ? { danced: true } : {
          danced: false, grade, equity_lost: lost, forced: false, n_legal: 9,
          played, best, top: grade === 'best' ? [best] : [best, played],
        },
        cube: null, luck: n % 3 === 0 ? 0.087 : -0.021,
      });
      before = e.position;
    } else if (e.kind === 'double') {
      const answer = game.entries[i + 1];
      const passed = answer && answer.kind === 'drop';
      turns.push({
        number: turns.length + 1, log_index: 0, entry: null, double_entry: i,
        answer_entry: answer && (answer.kind === 'take' || passed) ? i + 1 : null,
        seat: seat(e.player), player_id: e.player, color: color(e.player), dice: null,
        double: passed ? 'pass' : 'take', move: null, luck: null,
        cube: {
          action: 'double', response: passed ? 'pass' : 'take', optimal: 'No Double',
          equities: { no_double: 0.084, double_take: -0.283, double_pass: 1.0 },
          doubler: { seat: seat(e.player), grade: 'very_bad', equity_lost: 0.3675, mistake: 'wrong_double' },
          taker: { seat: 1 - seat(e.player), grade: passed ? 'very_bad' : 'ok', equity_lost: passed ? 1.28 : 0, mistake: passed ? 'wrong_pass' : null },
        },
      });
    }
  });
  const totals = (p, i) => ({
    seat: i, player_id: p.id, name: p.name, color: p.color, pr: i === 0 ? 8.43 : 12.07, error: 0.5, luck: i === 0 ? 0.412 : -0.412,
    moves: { decisions: 30, forced: 2, error: 0.4, grades: { best: 12, ok: 8, doubtful: 5, bad: 3, very_bad: 2 } },
    cube: { decisions: 4, error: 0.1, mistakes: { missed_double: 0, wrong_double: 1, wrong_take: 0, wrong_pass: 0 } },
  });
  return { levels: { moves: '4ply', cube: '4ply' }, timing_ms: 61000, players: record.players.map(totals), turns };
}

/** Answer `/reviews`, `/reviews/<n>` and the retry in the browser.
 *
 * The index is the cheap answer the page polls; one game's analysis is
 * asked for on its own, and only for the game being read.
 */
async function stubAnalysis(context, record, counts) {
  let retried = false;
  const statusOf = (g) => {
    if (g.number === 1 && !retried) return counts.get >= 3 ? 'failed' : 'pending';
    return counts.get < 3 ? 'pending' : 'done';
  };
  const turnsOf = (g) => g.entries.filter((e) => e.kind === 'turn').length;
  const index = () => ({
    ok: true,
    players: record.players.map((p, i) => ({ seat: i, player_id: p.id, name: p.name, color: p.color })),
    games: record.games.map((g) => ({ game_number: g.number, status: statusOf(g), turns: turnsOf(g) })),
  });
  const one = (number) => {
    const g = record.games.find((x) => x.number === number);
    if (!g) return { ok: false, error: { code: 'not_found', message: 'no such game' } };
    const status = statusOf(g);
    return { ok: true, game_number: number, status, turns: turnsOf(g), review: status === 'done' ? reviewOf(record, g) : null };
  };
  // Nothing here carries anything in the URL but the game number: who is
  // asking is the guest cookie the request goes out with.
  await context.route(/\/papi\/games\/backgammon\/rooms\/[^/]+\/reviews(\/(retry|\d+))?(\?|$)/, async (route) => {
    const url = route.request().url();
    const game = url.match(/\/reviews\/(\d+)/);
    let body;
    if (url.includes('/reviews/retry')) {
      counts.retry += 1;
      retried = true;
      body = index();
    } else if (game) {
      counts.game += 1;
      body = one(Number(game[1]));
    } else {
      counts.get += 1;
      body = index();
    }
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });
}

module.exports = { reviewOf, stubAnalysis };
