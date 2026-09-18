/**
 * Backgammon replay: a finished match played again, with its analysis.
 *
 * The room is arranged by `setup.exs` (a finished match to 3 of several
 * games, found by random play and replayed into a real room). Then:
 *
 * 1. Desktop 1440x900: the replay opens on the match's last game at the
 *    start; the analysis says it is running ("Analysing game N at 4-ply…")
 *    while `/reviews` answers pending; stepping with the buttons and the
 *    arrow keys moves one line at a time; when the analysis lands (the
 *    page polls) the grades fill in and the viewer stays on the same step;
 *    a candidate move goes on the board and comes off again; the ANALYSIS
 *    tab shows each player's PR; End goes to the last line.
 * 2. A game whose analysis failed says so and offers TRY AGAIN, which
 *    re-asks (a POST) and fills the game in.
 * 3. Polling stops once nothing is pending.
 * 4. Phone 390x844, 320x568 and 844x390: nothing scrolls sideways, the
 *    board fits the screen, a swipe across the board steps, and the
 *    current line of the move list is in view.
 * 5. The table offers REPLAY at game over, and it opens this page.
 *
 * The analysis is stubbed by default: `/reviews` (the index: a status and a
 * turn count per game) and `/reviews/<n>` (one game's analysis) are both
 * answered in the browser, the analysis built from the room's own record
 * (every verdict names a real line of it), pending for the first few asks,
 * then done -- except game 1, which fails until retried. With REPLAY_REAL=1 the real endpoint
 * is used and the script waits for the engine (needs ANALYSIS_URL
 * reachable by the server).
 *
 * Run with the server up:  node playwright/test-backgammon-replay/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const SHOTS = process.env.SHOTS_DIR || 'playwright/screenshots/test-backgammon-replay';
const REAL = process.env.REPLAY_REAL === '1';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrangeRoom() {
  if (process.env.REPLAY_JSON) return JSON.parse(process.env.REPLAY_JSON);
  log('arranging a finished match (mix run playwright/test-backgammon-replay/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-replay/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

// ---------- the stubbed analysis ----------

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
        seat: seat(e.player), player_id: e.player, color: color(e.player), dice: e.dice, picked: false, double: null,
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
        seat: seat(e.player), player_id: e.player, color: color(e.player), dice: null, picked: false,
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

// ---------- checks ----------

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

async function boardFits(page, what) {
  const b = await page.locator('.bg-still .bg-stack').boundingBox();
  const vp = page.viewportSize();
  must(b.x >= 0 && b.x + b.width <= vp.width + 1, `${what}: the board is within the screen's width`);
  must(b.y >= -1 && b.y + b.height <= vp.height + 1, `${what}: the board is within the screen's height`);
  return b;
}

/** The step counter, once it has settled on `expected` (the board renders
 * on the next frame after a step), or whatever it says after two seconds. */
async function count(page, expected) {
  // The page prints no counter; the row carries the step and the last step
  // as data attributes, read here as the old label read ("START", "4 / 82").
  const read = () => {
    const w = document.querySelector('.rp-controls-wrap');
    const step = Number(w.dataset.step), last = Number(w.dataset.last);
    return step === 0 ? 'START' : `${step} / ${last}`;
  };
  if (expected !== undefined) {
    await page.waitForFunction((want) => {
      const w = document.querySelector('.rp-controls-wrap');
      const step = Number(w.dataset.step), last = Number(w.dataset.last);
      return (step === 0 ? 'START' : `${step} / ${last}`) === want;
    }, expected, { timeout: 2000 }).catch(() => {});
  } else {
    await sleep(100);
  }
  return page.evaluate(read);
}

async function currentLineVisible(page, what) {
  // The page opens on ANALYSIS; the list this checks is a tab away.
  if (!(await page.locator('#rp-list').count())) await page.click('.rp-tab:has-text("MOVES")');
  // the list scrolls to the line a frame after the step renders
  const inView = await page
    .waitForFunction(() => {
      const line = document.querySelector('.rp-line.is-on');
      const list = document.getElementById('rp-list');
      if (!line || !list) return false;
      const a = line.getBoundingClientRect();
      const b = list.getBoundingClientRect();
      return a.top >= b.top - 1 && a.bottom <= b.bottom + 1;
    }, null, { timeout: 2000 })
    .then(() => true, () => false);
  if (!inView) {
    await page.screenshot({ path: `${SHOTS}/failed-${what}.png` });
    log(JSON.stringify(await page.evaluate(() => {
      const line = document.querySelector('.rp-line.is-on');
      const list = document.getElementById('rp-list');
      return { line: line && line.getBoundingClientRect(), list: list && list.getBoundingClientRect(), scroll: list && list.scrollTop };
    })));
  }
  must(inView, `${what}: the current line of the move list is in view`);
}

async function swipe(page, dx) {
  await page.evaluate((dx) => {
    const el = document.getElementById('rp-board');
    const r = el.getBoundingClientRect();
    const y = r.top + r.height / 2;
    const x0 = r.left + r.width / 2 - dx / 2;
    const touch = (x) => new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
    el.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, touches: [touch(x0)], changedTouches: [touch(x0)] }));
    el.dispatchEvent(new TouchEvent('touchend', { bubbles: true, touches: [], changedTouches: [touch(x0 + dx)] }));
  }, dx);
  await sleep(250);
}

async function main() {
  const room = arrangeRoom();
  const alice = room.players[0];
  fs.mkdirSync(SHOTS, { recursive: true });
  // A replay link carries no credential: it is the room's plain URL. Alice's
  // own browser is told the record is hers because of her guest cookie, set
  // on the contexts below.
  const url = (extra = '') => `${BASE}/backgammon/${room.game_id}/replay${extra.replace(/^&/, '?')}`;
  const asAlice = async (context) => {
    await context.addCookies([
      { name: '_oskol_guest', value: alice.guest, url: BASE, httpOnly: true, sameSite: 'Lax' },
    ]);
    return context;
  };

  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    // The record as the page reads it, for the stub to build on.
    const api = await playwright.request.newContext({
      extraHTTPHeaders: { cookie: `_oskol_guest=${alice.guest}` },
    });
    const res = await api.get(`${BASE}/papi/games/backgammon/rooms/${room.game_id}/record`);
    const recordBody = await res.json();
    must(recordBody.ok && recordBody.you === alice.id && recordBody.seated,
      "the record names the reader's own seat, from their guest cookie");
    const record = recordBody.record;
    must(record.games.length > 1 && record.start && record.cube === true, `the record has ${record.games.length} games, a start position and a cube`);
    const last = record.games[record.games.length - 1];
    log(`room ${room.game_id}: ${record.games.length} games, the last ${last.entries.length} lines (analysis ${REAL ? 'REAL' : 'stubbed'})`);

    // ---------- 1. desktop ----------
    const desktop = await asAlice(await browser.newContext({ viewport: { width: 1440, height: 900 } }));
    await desktop.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const counts = { get: 0, retry: 0, game: 0 };
    if (!REAL) await stubAnalysis(desktop, record, counts);
    const page = await desktop.newPage();
    watch(page, 'desktop');
    await page.goto(url());
    await page.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
    must((await count(page)) === 'START', 'the replay opens at the start of a game');
    // The match panel (under the board, between the arrows) marks the game on the board.
    await page.click('#rp-match');
    await page.waitForSelector('#bg-match-sheet');
    must(await page.locator(`.rp-match-row[data-game="${last.number}"].is-on`).count() === 1, `it opens the match's last game (${last.number})`);
    await page.click('#bg-match-close');
    await page.waitForSelector('#bg-match-sheet', { state: 'detached' });
    if (!REAL) {
      await page.waitForSelector('#rp-analysis-state.is-pending', { timeout: 5000 });
      must(/Analysing game \d+ at 4-ply… this can take a few minutes/.test(await page.textContent('#rp-analysis-state')), 'a pending analysis says so, and that it takes a while');
      await page.screenshot({ path: `${SHOTS}/01-desktop-pending.png` });
    }

    await page.click('#rp-next');
    await page.click('#rp-next');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowLeft');
    { const c = await count(page, `4 / ${last.entries.length}`); must(c === `4 / ${last.entries.length}`, `buttons and arrow keys step one line at a time (${c})`); }
    const landed = await page.locator('.bg-still .checker.just-moved').count();
    must(landed > 0, 'a turn marks the checkers it landed');

    // The analysis lands while the viewer is on step 4.
    await page.waitForSelector('#rp-note .rp-grade', { timeout: REAL ? 180000 : 15000 });
    must((await count(page, `4 / ${last.entries.length}`)) === `4 / ${last.entries.length}`, 'the grades fill in without moving the viewer');
    // The page opens on ANALYSIS; the move list is a tab away.
    await page.click('.rp-tab:has-text("MOVES")');
    await page.waitForSelector('.rp-line');
    must(await page.locator('.rp-line .rp-mark').count() > 0, 'the move list carries the grades');

    // Find a turn that was not the engine's best, and put its best on the board.
    let found = false;
    for (let i = 0; i < last.entries.length && !found; i++) {
      await sleep(60);
      if (await page.locator('.rp-cand:not(.is-played)').count() > 0) { found = true; break; }
      await page.keyboard.press('ArrowRight');
    }
    must(found, 'some turn has a better move to show');
    const before = await page.locator('.bg-still').innerHTML();
    await page.click('.rp-cand:not(.is-played)');
    await page.waitForSelector('.rp-board.is-proposed');
    must((await page.locator('.bg-still').innerHTML()) !== before, 'a proposed move is drawn on the board');
    await page.screenshot({ path: `${SHOTS}/02-desktop-best-move.png` });
    await page.click('.rp-cand.is-played');
    await page.waitForSelector('.rp-board.is-proposed', { state: 'detached', timeout: 2000 }).catch(() => {});
    must(await page.locator('.rp-board.is-proposed').count() === 0, 'and the played move comes back');
    await page.screenshot({ path: `${SHOTS}/03-desktop-graded.png` });

    await page.click('.rp-tab:has-text("ANALYSIS")');
    await page.waitForSelector('#rp-summary .rp-pr');
    must(await page.locator('#rp-summary .rp-pr').count() === 2, 'the summary gives both players a PR');
    await page.screenshot({ path: `${SHOTS}/04-desktop-summary.png` });
    await page.click('.rp-tab:has-text("MOVES")');

    await page.keyboard.press('End');
    must((await count(page, `${last.entries.length} / ${last.entries.length}`)) === `${last.entries.length} / ${last.entries.length}`, 'End goes to the last line');
    await currentLineVisible(page, 'desktop');

    // ---------- 2. a failed game, tried again ----------
    if (!REAL) {
      await page.click('#rp-match');
      await page.click('.rp-match-row[data-game="1"]');
      await page.waitForSelector('#rp-analysis-state.is-failed');
      must(await page.locator('#rp-retry').count() === 1, 'a failed analysis offers to try again');
      await page.screenshot({ path: `${SHOTS}/05-desktop-failed.png` });
      await page.click('#rp-retry');
      await page.waitForFunction(() => !document.querySelector('#rp-analysis-state.is-failed'), null, { timeout: 5000 });
      must(counts.retry === 1, 'TRY AGAIN asked the server once');

      // ---------- 3. polling stops ----------
      const asked = counts.get;
      await sleep(7000);
      must(counts.get === asked, `nothing pending: no more asks (${asked} in all)`);
    }
    await page.close();
    await desktop.close();

    // ---------- 4. phones ----------
    for (const phone of [
      { name: 'phone', width: 390, height: 844 },
      { name: 'phone-small', width: 320, height: 568 },
      { name: 'landscape', width: 844, height: 390 },
    ]) {
      const ctx = await asAlice(await browser.newContext({ viewport: { width: phone.width, height: phone.height }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }));
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      if (!REAL) await stubAnalysis(ctx, record, { get: 5, retry: 0 });
      const p = await ctx.newPage();
      watch(p, phone.name);
      await p.goto(url(`&game=${last.number}`));
      await p.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
      await p.waitForSelector('#rp-note', { timeout: 20000 });
      await sleep(REAL ? 3000 : 500);
      await swipe(p, -120);
      await swipe(p, -120);
      await swipe(p, -120);
      must((await count(p, `3 / ${last.entries.length}`)) === `3 / ${last.entries.length}`, `${phone.name}: a swipe left steps forward`);
      await swipe(p, 120);
      must((await count(p, `2 / ${last.entries.length}`)) === `2 / ${last.entries.length}`, `${phone.name}: a swipe right steps back`);
      await swipe(p, 10);
      must((await count(p)) === `2 / ${last.entries.length}`, `${phone.name}: a short touch is not a step`);
      for (let i = 0; i < 8; i++) await p.click('#rp-next');
      await sleep(400);
      await noSideways(p, phone.name);
      for (const control of ['#rp-first', '#rp-last']) {
        const b = await p.locator(control).boundingBox();
        must(b.x >= 0 && b.x + b.width <= phone.width + 1, `${phone.name}: ${control} is inside the screen`);
      }
      const board = await boardFits(p, phone.name);
      if (phone.name === 'landscape') {
        const side = await p.locator('.rp-side').boundingBox();
        must(side.x >= board.x + board.width - 1, 'landscape: the notes sit beside the board, not on it');
      }
      await currentLineVisible(p, phone.name);
      await p.screenshot({ path: `${SHOTS}/06-${phone.name}.png` });
      await ctx.close();
    }

    // ---------- 5. the table's door ----------
    const table = await asAlice(await browser.newContext({ viewport: { width: 1280, height: 860 } }));
    await table.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    if (!REAL) await stubAnalysis(table, record, { get: 5, retry: 0 });
    const t = await table.newPage();
    watch(t, 'table');
    await t.goto(`${BASE}/backgammon/${room.game_id}`);
    await t.waitForSelector('#bg-replay', { timeout: 20000 });
    await t.click('#bg-replay');
    await t.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
    must(/\/replay\?game=\d+$/.test(t.url()), 'REPLAY at game over opens this game\'s replay, with no token in the link');
    await table.close();

    must(errors.length === 0, `no page errors${errors.length ? ': ' + errors.join(' | ') : ''}`);
    log('all replay checks passed');
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
