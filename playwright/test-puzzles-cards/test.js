/**
 * PRACTICE THIS GAME'S N MISTAKES, from the result cards. `setup.exs`
 * arranges an unlimited session with two finished games (its table shows
 * the between-games card of the second) and a single finished game (the
 * game-over card), both graded against a stubbed engine, the same two
 * guests seated in both. Then:
 *
 *  1. Alice, a guest, opens the unlimited table: the between-games card
 *     carries the button with her own count for game 2 (checked against
 *     what /puzzles?game=2 answers her, and against the rows), the save
 *     offer, and READY beside them, unobscured. The offer opens the sign-in
 *     as a sheet that leaves READY where it is, and closes.
 *  2. She presses the button and plays the run through: as many puzzles as
 *     the count said, then the score and the sign-in ask.
 *  3. She signs in there (the mail read from /dev/last-login): both games
 *     come along, and CONTINUE brings her back to the table -- the card
 *     now without the offer, the button still there.
 *  4. On the single game's table, the game-over card has the button with
 *     that game's count and no offer; the run, as an account, shows the
 *     level line on every reveal (the deck holds them) and ends on the
 *     account's screen, not the ask.
 *  5. Bob, still a guest, is offered his own count on the unlimited table,
 *     not Alice's.
 *  6. Phones: both cards at 390x844, 320x568 and 844x390, as a guest, to
 *     playwright/screenshots/test-puzzles-cards.
 *
 * Run with the dev server up (/dev routes on):
 *   node playwright/test-puzzles-cards/test.js
 */
const playwright = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { mailFor, playRun, sleep } = require('../lib/puzzles');

const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const SHOTS = path.join(__dirname, '..', 'screenshots', 'test-puzzles-cards');

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrange() {
  if (process.env.CARDS_JSON) return JSON.parse(process.env.CARDS_JSON);
  log('arranging two graded rooms (mix run playwright/test-puzzles-cards/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzles-cards/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(resultLine(out));
}

const label = (n) => `PRACTICE THIS GAME'S ${n} MISTAKE${n === 1 ? '' : 'S'}`;

/** What /puzzles?game=n answers this browser: the ids, or the status. */
async function mistakesOf(page, gameId, n) {
  const res = await page.request.get(`${BASE}/papi/games/backgammon/rooms/${gameId}/puzzles?game=${n}`);
  if (!res.ok()) return { status: res.status() };
  const body = await res.json();
  return { status: 200, ids: body.puzzles.map((p) => p.id) };
}

/** The button, once the page has counted (the puzzles may still be being
 * written for a moment after the grade; the page asks again). */
async function practiceButton(page) {
  await page.waitForSelector('#practice-game', { timeout: 20000 });
  return {
    text: (await page.textContent('#practice-game')).trim(),
    game: await page.getAttribute('#practice-game', 'data-game'),
    count: Number(await page.getAttribute('#practice-game', 'data-count')),
  };
}

/** Whether the element with `id` is what a tap at its centre would hit. */
async function reachable(page, id) {
  return page.evaluate((sel) => {
    const el = document.getElementById(sel);
    if (!el) return false;
    const r = el.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return hit === el || el.contains(hit);
  }, id);
}

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

async function run(browser, setup, errors) {
  const A = setup.unlimited;
  const B = setup.single;
  const [alice, bob] = setup.players;
  const contexts = [];
  const open = async (who, context) => {
    contexts.push(context);
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
    return page;
  };
  fs.mkdirSync(SHOTS, { recursive: true });

  try {
    // ---- 1. Alice, a guest, on the between-games card ----
    const a = await open('alice', await seatedContext(browser, alice.guest, { viewport: { width: 390, height: 844 } }));
    await a.goto(`${BASE}/backgammon/${A.game_id}`);
    await a.waitForSelector('#bg-game-result');
    must(await a.locator('#bg-action-ready').count(), 'the second game is over and READY is offered');
    const between = await practiceButton(a);
    const expectedA = A.counts['2'][A.seats.p1];
    must(between.game === '2', `the card names the game just played (game ${between.game})`);
    must(between.count === expectedA && between.text === label(expectedA), `the count is the rows' own for this seat: "${between.text}"`);
    const mineA = await mistakesOf(a, A.game_id, 2);
    must(mineA.status === 200 && mineA.ids.length === expectedA, `and what /puzzles?game=2 answers this browser (${mineA.ids && mineA.ids.length})`);
    must(!(await a.locator('#practice-none').count()), 'no "no mistakes" line beside a count');
    must(await a.locator('#bg-game-result #save-offer').count(), 'the between-games card makes the save offer to a guest');
    must(await reachable(a, 'bg-action-ready'), 'READY is unobscured with the card full');

    for (const size of [{ w: 390, h: 844 }, { w: 320, h: 568 }, { w: 844, h: 390 }]) {
      await a.setViewportSize({ width: size.w, height: size.h });
      await sleep(250);
      await noSideways(a, `between games at ${size.w}x${size.h}`);
      must(await a.locator('#practice-game').isVisible(), `the button is on screen at ${size.w}x${size.h}`);
      must(await reachable(a, 'bg-action-ready'), `READY is unobscured at ${size.w}x${size.h}`);
      await a.screenshot({ path: path.join(SHOTS, `between-games-${size.w}x${size.h}.png`) });
    }
    await a.setViewportSize({ width: 390, height: 844 });

    // The offer opens the sign-in as a sheet, READY still under it, and closes.
    await a.click('#save-offer');
    await a.waitForSelector('#bg-save-sheet #signin-email');
    must(await a.locator('#bg-action-ready').count(), 'READY is still in the band while the sign-in sheet is up');
    await a.click('#save-close');
    await sleep(150);
    must(!(await a.locator('#bg-save-sheet').count()), 'and the sheet closes');
    must(await reachable(a, 'bg-action-ready'), 'READY is reachable again');

    // ---- 2. the run, to the ask ----
    await a.click('#practice-game');
    await a.waitForURL(/\/puzzles\/[A-Za-z0-9]+$/);
    must(a.url().endsWith(`/puzzles/${mineA.ids[0]}`), 'PRACTICE opens the first of this seat\'s mistakes in game 2');
    const answered = await playRun(a, {
      onReveal: async (page) => {
        if (await page.locator('#pz-level').count()) throw new Error('a guest has no level line');
      },
    });
    must(answered === expectedA, `the run is every mistake of the game, in order (${answered})`);
    await a.waitForSelector('#pz-signin-ask');
    const score = (await a.textContent('#pz-score')).trim();
    must(new RegExp(`^\\d+ of ${expectedA} right$`).test(score), `the score: "${score}"`);
    must(await a.locator('#pz-signin-ask').count(), 'a guest is asked to sign in at the end');

    // ---- 3. signing in there brings her back to the table ----
    const email = `cards-${Date.now()}@oskol.test`;
    await a.fill('#signin-email', email);
    await a.click('#signin-send');
    await a.waitForSelector('#signin-code');
    const mail = await mailFor(a.request, email);
    await a.fill('#signin-code', mail.code);
    await a.waitForSelector('#signin-win');
    const saved = (await a.textContent('#signin-saved')).trim();
    must(saved.startsWith('2 games saved'), `both games came with the account: "${saved}"`);
    await a.click('#signin-continue');
    await a.waitForURL(`${BASE}/backgammon/${A.game_id}`);
    must(true, 'CONTINUE returns to the table the run was started from');
    await a.waitForSelector('#bg-game-result');
    const again = await practiceButton(a);
    must(again.count === expectedA, 'the count is still there for the account');
    must(!(await a.locator('#save-offer').count()), 'and the offer is gone: nothing left to save');

    // The deck fills itself off the request (a queue job); when the queue
    // is busy with other rooms, the sweep by hand is the operator's lever.
    const deckCount = async () => {
      const res = await a.request.get(`${BASE}/papi/practice`);
      const body = await res.json();
      return (body.counts && body.counts.deck) || 0;
    };
    let deck = 0;
    for (let i = 0; i < 30 && deck === 0; i++) {
      deck = await deckCount();
      if (deck === 0) await sleep(500);
    }
    if (deck === 0) {
      log('the queue has not synced the deck yet: running mix oskol.puzzles.sync --write');
      execFileSync('mix', ['oskol.puzzles.sync', '--write'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      deck = await deckCount();
    }
    must(deck > 0, `the account's deck holds its mistakes (${deck})`);

    // ---- 4. the game-over card, as an account ----
    await a.goto(`${BASE}/backgammon/${B.game_id}`);
    await a.waitForSelector('#bg-review-moves');
    const over = await practiceButton(a);
    const expectedB = B.counts['1'][B.seats.p1];
    must(over.count === expectedB && over.text === label(expectedB), `the game-over card counts that game's: "${over.text}"`);
    must(!(await a.locator('#save-offer').count()), 'no offer to an account');
    await a.click('#practice-game');
    await a.waitForURL(/\/puzzles\/[A-Za-z0-9]+$/);
    let levels = 0;
    const answeredB = await playRun(a, {
      onReveal: async (page) => {
        if (await page.locator('#pz-level').count()) levels += 1;
      },
    });
    must(answeredB === expectedB, `the run is that game's mistakes (${answeredB})`);
    must(levels === answeredB, `every reveal carries the level line: the outcomes reach the deck (${levels})`);
    await a.waitForSelector('#pz-end');
    must(!(await a.locator('#pz-signin-ask').count()), 'an account is not asked to sign in');
    must(await a.locator('#pz-done, #pz-more-due, #pz-home, #pz-nothing-more').count(), 'and ends on the deck\'s own screen');

    // ---- 5. Bob's count is Bob's ----
    const b = await open('bob', await seatedContext(browser, bob.guest, { viewport: { width: 390, height: 844 } }));
    await b.goto(`${BASE}/backgammon/${A.game_id}`);
    await b.waitForSelector('#bg-game-result');
    const bobs = await practiceButton(b);
    const expectedBob = A.counts['2'][A.seats.p2];
    must(bobs.count === expectedBob, `the other seat is offered its own count (${bobs.count}, Alice's was ${expectedA})`);
    const mineBob = await mistakesOf(b, A.game_id, 2);
    must(mineBob.status === 200 && mineBob.ids.length === expectedBob && !mineBob.ids.some((id) => mineA.ids.includes(id)),
      'and none of Alice\'s puzzles are in his list');

    // ---- 6. the game-over card on phones, as a guest ----
    await b.goto(`${BASE}/backgammon/${B.game_id}`);
    await b.waitForSelector('#bg-review-moves');
    await practiceButton(b);
    must(await b.locator('#save-offer').count(), 'the game-over card still makes the offer to a guest');
    for (const size of [{ w: 390, h: 844 }, { w: 320, h: 568 }, { w: 844, h: 390 }]) {
      await b.setViewportSize({ width: size.w, height: size.h });
      await sleep(250);
      await noSideways(b, `game over at ${size.w}x${size.h}`);
      must(await b.locator('#practice-game').isVisible(), `the button is on screen at ${size.w}x${size.h}`);
      await b.screenshot({ path: path.join(SHOTS, `game-over-${size.w}x${size.h}.png`) });
    }
  } finally {
    for (const c of contexts) await c.close().catch(() => {});
  }
}

(async () => {
  const setup = arrange();
  log(`rooms ${setup.unlimited.game_id} (unlimited, ${setup.unlimited.games} games) and ${setup.single.game_id} (single)`);
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  try {
    await run(browser, setup, errors);
  } finally {
    await browser.close();
  }
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
  }
  log('puzzles cards smoke: all good');
})().catch((e) => { console.error(e); process.exit(1); });
