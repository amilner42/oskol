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
 *    a candidate move goes on the board and comes off again; OVERVIEW
 *    shows each player's PR and keeps the step; End goes to the last line.
 * 2. A game whose analysis failed says so and offers TRY AGAIN, which
 *    re-asks (a POST) and fills the game in.
 * 3. Polling stops once nothing is pending.
 *    board fits the screen, and a swipe across the board steps.
 *    Everywhere, the side is one panel under one bar of three tabs
 *    (OVERVIEW, MOVE, CUBE): the start opens on OVERVIEW with MOVE and
 *    CUBE greyed, a step opens MOVE, CUBE is offered on a roll only,
 *    OVERVIEW mid-game keeps the step and MOVE comes back to it, each
 *    shows its content alone; on a phone the page scrolls rather than
 *    any panel.
 * 5. The table offers REPLAY at game over, and it opens this page.
 *
 * The analysis is stubbed by default (`lib/replay-stub.js`): `/reviews`
 * (the index: a status and a turn count per game) and `/reviews/<n>` (one
 * game's analysis) are both answered in the browser, the analysis built
 * from the room's own record (every verdict names a real line of it),
 * pending for the first few asks, then done -- except game 1, which fails
 * until retried. With REPLAY_REAL=1 the real endpoint
 * is used and the script waits for the engine (needs ANALYSIS_URL
 * reachable by the server).
 *
 * Run with the server up:  node playwright/test-backgammon-replay/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');
const { stubAnalysis } = require('../lib/replay-stub');

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

/** The side is one panel under one bar of three tabs, OVERVIEW, MOVE and
 * CUBE, each showing its content alone; MOVE and CUBE are offered only
 * where they have something to say; OVERVIEW keeps the step. On a phone
 * the page scrolls, never a panel. Leaves the page where it found it. */
async function onePanel(page, what, { phone }) {
  const tabs = ['#rp-tab-overview', '#rp-note-move', '#rp-note-cube'];
  for (const tab of tabs) must(await page.locator(`#rp-panel .rp-tabs ${tab}`).count() === 1, `${what}: the one panel has the tab ${tab}`);
  must(await page.locator('.rp-panel').count() === 1 && await page.locator('.rp-tabs').count() === 1 && await page.locator('.rp-note-tabs').count() === 0, `${what}: one panel, one bar`);
  must(await page.locator('#rp-list, .rp-line').count() === 0, `${what}: no move list`);
  // The start: OVERVIEW, and neither MOVE nor CUBE is a door.
  const step = Number(await page.getAttribute('.rp-controls-wrap', 'data-step'));
  await page.click('#rp-first');
  await page.waitForFunction(() => document.querySelector('.rp-controls-wrap').dataset.step === '0', null, { timeout: 2000 });
  await page.waitForSelector('#rp-overview', { timeout: 2000 });
  must(await page.locator('#rp-tab-overview.is-on').count() === 1, `${what}: the start opens on OVERVIEW`);
  must(await page.locator('#rp-overview #rp-summary .rp-pr').count() === 2, `${what}: the overview is the summary, both PRs`);
  must(await page.locator('#practice-game').count() === 0, `${what}: nothing to press for practice on the overview`);
  must(await page.locator('#rp-note-move:disabled').count() === 1 && await page.locator('#rp-note-cube:disabled').count() === 1, `${what}: MOVE and CUBE are not offered before the first roll`);
  // A roll: MOVE is its verdict, CUBE its other side.
  for (let i = 0; i < step; i++) await page.click('#rp-next');
  await page.waitForFunction((want) => document.querySelector('.rp-controls-wrap').dataset.step === String(want), step, { timeout: 2000 });
  await page.waitForSelector('#rp-note-cube:enabled', { timeout: 2000 });
  must(await page.locator('#rp-note-move.is-on').count() === 1 && await page.locator('#rp-panel > #rp-note .rp-grade').count() === 1, `${what}: a step opens MOVE, that move's verdict`);
  await page.click('#rp-note-cube');
  await page.waitForSelector('#rp-note-cube.is-on', { timeout: 2000 });
  must(await page.locator('#rp-panel > #rp-note').count() === 1 && await page.locator('#rp-overview').count() === 0, `${what}: CUBE shows the note alone`);
  // OVERVIEW mid-game keeps the step; MOVE is the way back.
  await page.click('#rp-tab-overview');
  await page.waitForSelector('#rp-overview', { timeout: 2000 });
  must(Number(await page.getAttribute('.rp-controls-wrap', 'data-step')) === step && await page.locator('#rp-note').count() === 0, `${what}: OVERVIEW mid-game keeps step ${step} and shows the overview alone`);
  must(await page.locator('.rp-tab.is-on').count() === 1, `${what}: one tab is on`);
  if (phone) {
    // The overview is the tallest: the page, not the panel, is what scrolls.
    const scroll = await page.evaluate(() => ({
      page: document.scrollingElement.scrollHeight > innerHeight,
      panels: [...document.querySelectorAll('.rp-panel, .rp-note, .rp-summary, .rp-overview')].filter((el) => el.scrollHeight > el.clientHeight + 1).length,
    }));
    must(scroll.page, `${what}: the page scrolls`);
    must(scroll.panels === 0, `${what}: no panel scrolls inside itself`);
  }
  await page.click('#rp-note-move');
  await page.waitForSelector('#rp-note-move.is-on', { timeout: 2000 });
  must(Number(await page.getAttribute('.rp-controls-wrap', 'data-step')) === step && await page.locator('#rp-note .rp-grade').count() === 1, `${what}: MOVE comes back to step ${step}'s verdict`);
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

    await page.click('#rp-tab-overview');
    await page.waitForSelector('#rp-overview .rp-pr');
    must(await page.locator('#rp-overview .rp-pr').count() === 2, 'the overview gives both players a PR');
    await page.screenshot({ path: `${SHOTS}/04-desktop-summary.png` });
    await onePanel(page, 'desktop', { phone: false });

    await page.keyboard.press('End');
    must((await count(page, `${last.entries.length} / ${last.entries.length}`)) === `${last.entries.length} / ${last.entries.length}`, 'End goes to the last line');

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
      await p.waitForSelector('#rp-panel', { timeout: 20000 });
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
      await onePanel(p, phone.name, { phone: true });
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
