/**
 * The card between games: one row in the board's centre band, at the
 * band's own height, in every layout. Left half: who won and by how much.
 * Right half: NEXT, and END where the room offers it (unlimited play only).
 * Nothing else: no score line, no REPLAY, no practice, no save offer, no
 * line saying the opponent is ready.
 *
 * Three rooms on every screen, each game ended by a resignation so nothing
 * here needs the engine:
 *
 *  - a match to 5 against Sage, resigned as a backgammon (what Sage accepts
 *    at the opening): SAGE WINS +3 and NEXT alone, since a match has no
 *    ending early;
 *  - unlimited against Sage: SAGE WINS +1, NEXT and END, and Sage's
 *    readiness never drawn. Sage declines a single at the opening and a
 *    centred cube under Jacoby offers nothing else, so `setup.exs` ends this
 *    room's first game before the browser opens it;
 *  - unlimited between two people: the one who presses NEXT second sees the
 *    other's readiness as a dot inside NEXT ("They're ready"), and the one
 *    who pressed first a greyed NEXT, neither of which moves anything.
 *
 * The board, both halves, both bands and the card are held box for box:
 * playing, then between games (and while the other player gets ready), then
 * the next game. The arranged room starts between games, so it holds the
 * card against the next game's board.
 *
 * Screens: 390x844, 320x568, 844x390 in focus mode and compressed, 667x375,
 * 1440x900. Screenshots go to playwright/screenshots/test-between-games.
 *
 * Run with the server up:  node playwright/test-between-games/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { BASE, createGame, joinByLink, resultLine } = require('../lib/flows');

const OUT = path.join(__dirname, '..', 'screenshots', 'test-between-games');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SCREENS = [
  { name: '390x844', width: 390, height: 844 },
  { name: '320x568', width: 320, height: 568 },
  { name: '844x390-focus', width: 844, height: 390, focus: true },
  { name: '844x390-compressed', width: 844, height: 390, focus: false },
  { name: '667x375', width: 667, height: 375, focus: true },
  { name: '1440x900', width: 1440, height: 900 },
];

function must(condition, message) {
  if (!condition) throw new Error(message);
}

const guest = () => require('crypto').randomBytes(16).toString('base64url');

function arrange() {
  log('arranging the unlimited rooms against Sage (setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-between-games/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, BETWEEN_ROOMS: String(SCREENS.length) },
  });
  return JSON.parse(resultLine(out)).rooms;
}

async function context(browser, vp, seat = guest()) {
  const c = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    hasTouch: vp.width < 1024,
    isMobile: vp.width < 1024,
    deviceScaleFactor: 1,
  });
  await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  await c.addCookies([{ name: '_oskol_guest', value: seat, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
  return c;
}

/** Every box the band could push around, rounded to the half pixel. */
async function boxes(page) {
  return page.evaluate(() => {
    const r = (el) => {
      if (!el) return null;
      const b = el.getBoundingClientRect();
      const q = (n) => Math.round(n * 2) / 2;
      return { x: q(b.x), y: q(b.y), w: q(b.width), h: q(b.height) };
    };
    const all = (sel) => Array.from(document.querySelectorAll(sel)).map(r);
    return {
      board: r(document.querySelector('.bg-board')),
      halves: all('.bg-half'),
      bands: all('.bg-board .bg-band'),
      points: all('.bg-board .bg-point').filter((_, i, a) => i === 0 || i === a.length - 1),
    };
  });
}

function same(a, b, what) {
  const sa = JSON.stringify(a);
  const sb = JSON.stringify(b);
  must(sa === sb, `${what}: the table moved\n  before ${sa}\n  after  ${sb}`);
}

/** The card's own boxes: the result, each button, and the dot. */
async function cardBoxes(page) {
  return page.evaluate(() => {
    const r = (sel) => {
      const el = document.querySelector(sel);
      if (!el) return null;
      const b = el.getBoundingClientRect();
      const q = (n) => Math.round(n * 2) / 2;
      return { x: q(b.x), y: q(b.y), w: q(b.width), h: q(b.height) };
    };
    return {
      result: r('#bg-game-result'),
      next: r('#bg-action-ready') || r('#bg-next-waiting'),
      end: r('#bg-action-close'),
    };
  });
}

/** What the card says and offers, and that it is one row inside the band. */
async function assertCard(page, { winner, end, what }) {
  await page.waitForSelector('#bg-game-result');
  const card = await page.evaluate(() => {
    const box = (el) => el && el.getBoundingClientRect();
    const result = document.getElementById('bg-game-result');
    const leftBand = result.closest('.bg-band');
    const next = document.getElementById('bg-action-ready') || document.getElementById('bg-next-waiting');
    const end = document.getElementById('bg-action-close');
    const rightBand = next && next.closest('.bg-band');
    const inside = (el, band) => {
      const a = box(el);
      const b = box(band);
      return a.left >= b.left - 0.5 && a.right <= b.right + 0.5 && a.top >= b.top - 0.5 && a.bottom <= b.bottom + 0.5;
    };
    return {
      text: result.innerText.replace(/\s+/g, ' ').trim(),
      resultInside: inside(result, leftBand),
      nextText: next && next.innerText.trim(),
      nextInside: next && inside(next, rightBand),
      endText: end && end.innerText.trim(),
      endLabel: end && end.getAttribute('aria-label'),
      endInside: end && inside(end, rightBand),
      oneRow: !end || Math.abs(box(end).top + box(end).height / 2 - (box(next).top + box(next).height / 2)) < 1,
      sameBand: !end || end.closest('.bg-band') === rightBand,
      clippedResult: result.scrollWidth > result.clientWidth + 1,
      extras: ['#practice-game', '#practice-none', '#save-offer', '.bg-replay-link', '#bg-ready-status', '#bg-save-sheet']
        .filter((s) => document.querySelector(s)),
      bandText: Array.from(document.querySelectorAll('.bg-board .bg-band')).map((b) => b.innerText.replace(/\s+/g, ' ').trim()).join(' | '),
    };
  });
  must(card.text.replace(/ /g, '') === winner.replace(/ /g, ''), `${what}: the result reads "${card.text}", wanted "${winner}"`);
  must(card.resultInside, `${what}: the result sits inside its half of the band`);
  must(!card.clippedResult, `${what}: the result is not cut off`);
  must(card.nextText === 'NEXT', `${what}: NEXT is offered ("${card.nextText}")`);
  must(card.nextInside, `${what}: NEXT sits inside its half of the band`);
  if (end) {
    must(card.endText === 'END' && card.endLabel === 'End the session', `${what}: END, labelled "End the session" (${card.endText}, ${card.endLabel})`);
    must(card.endInside && card.sameBand, `${what}: END sits beside NEXT inside the band`);
    must(card.oneRow, `${what}: NEXT and END are one row`);
  } else {
    must(card.endText === null, `${what}: no END in a match`);
  }
  must(card.extras.length === 0, `${what}: nothing else on the card (${card.extras.join(', ')})`);
  must(!/[0-9]+-[0-9]+|DROP|REPLAY|PRACTICE|READY/.test(card.bandText), `${what}: the band says only the result and the buttons ("${card.bandText}")`);
  const sideways = await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth);
  must(sideways, `${what}: nothing scrolls sideways`);
}

/** Into the layout the screen is checked in (a sideways phone only). */
async function settle(page, vp) {
  await page.waitForSelector('.bg-board .checker', { timeout: 20000 });
  if (vp.focus === false && (await page.locator('.bg-page.is-expanded').count())) {
    await page.click('#bg-focus-toggle');
  }
  if (vp.focus === true) must(await page.locator('.bg-page.is-expanded').count(), `${vp.name}: focus mode is the default`);
  await sleep(1400); // the opening tumble
}

/** Offer a single game's resignation; focus mode keeps the flag in the
 * other layout, so step out for it and back. */
async function resign(page, vp, stakes = 'single') {
  const focus = vp.focus === true;
  if (focus) await page.click('#bg-focus-toggle');
  await page.click('#bg-resign-open');
  await page.waitForSelector(`#bg-resign-${stakes}`);
  await page.click(`#bg-resign-${stakes}`);
  if (focus) {
    await sleep(200);
    await page.click('#bg-focus-toggle');
  }
}

/** A match to 5 against Sage, played into and out of the pause live. */
async function matchAgainstSage(browser, vp) {
  const what = `${vp.name}, match v Sage`;
  const c = await context(browser, vp);
  const page = await c.newPage();
  try {
    await createGame(page, { mode: 'match5', opponent: 'bot' });
    await settle(page, vp);
    const playing = await boxes(page);

    await resign(page, vp, 'backgammon');
    await page.waitForSelector('#bg-game-result', { timeout: 20000 });
    await sleep(900);
    await assertCard(page, { winner: 'SAGE WINS +3', end: false, what });
    must(!(await page.locator('#bg-ready-dot').count()), `${what}: Sage's readiness is never drawn`);
    same(playing, await boxes(page), `${what}, between games`);
    await page.screenshot({ path: path.join(OUT, `${vp.name}-match-sage.png`) });

    await page.click('#bg-action-ready');
    await page.waitForSelector('#bg-game-result', { state: 'detached', timeout: 20000 });
    await sleep(1400);
    same(playing, await boxes(page), `${what}, the next game`);
    log(`ok: ${what}`);
  } finally {
    await c.close();
  }
}

/** Unlimited play against Sage, opened between its games (setup.exs). */
async function unlimitedAgainstSage(browser, vp, room) {
  const what = `${vp.name}, unlimited v Sage`;
  const c = await context(browser, vp, room.guest);
  const page = await c.newPage();
  try {
    await page.goto(`${BASE}/backgammon/${room.game_id}`);
    await settle(page, vp);
    await assertCard(page, { winner: 'SAGE WINS +1', end: true, what });
    must(!(await page.locator('#bg-ready-dot').count()), `${what}: Sage's readiness is never drawn`);
    const between = await boxes(page);
    await page.screenshot({ path: path.join(OUT, `${vp.name}-unlimited-sage.png`) });

    await page.click('#bg-action-ready');
    await page.waitForSelector('#bg-game-result', { state: 'detached', timeout: 20000 });
    await sleep(1400);
    same(between, await boxes(page), `${what}, the next game`);
    log(`ok: ${what}`);
  } finally {
    await c.close();
  }
}

async function twoPeople(browser, vp) {
  const what = `${vp.name}, unlimited, two people`;
  const ca = await context(browser, vp);
  const cb = await context(browser, vp);
  const a = await ca.newPage();
  const b = await cb.newPage();
  try {
    const game = await createGame(a, { name: 'Ada', mode: 'unlimited' });
    await joinByLink(b, game.inviteUrl, 'Borisov');
    await a.waitForURL(`**/backgammon/${game.gameId}**`);
    await settle(a, vp);
    await settle(b, vp);
    const playing = await boxes(a);

    await resign(b, vp);
    await a.waitForSelector('#bg-action-accept_resign', { timeout: 15000 });
    await a.click('#bg-action-accept_resign');
    await a.waitForSelector('#bg-game-result');
    await b.waitForSelector('#bg-game-result');
    await sleep(900);
    await assertCard(a, { winner: 'YOU WIN +1', end: true, what: `${what} (the winner)` });
    await assertCard(b, { winner: 'ADA WINS +1', end: true, what: `${what} (the loser)` });
    must(!(await a.locator('#bg-ready-dot').count()), `${what}: no dot before anyone is ready`);
    same(playing, await boxes(a), `${what}, between games`);
    const before = await cardBoxes(a);
    const beforeB = await cardBoxes(b);

    // Borisov presses first: Ada's NEXT carries the dot, nothing moves.
    await b.click('#bg-action-ready');
    await b.waitForSelector('#bg-next-waiting');
    await a.waitForSelector('#bg-action-ready #bg-ready-dot');
    must((await a.getAttribute('#bg-ready-dot', 'aria-label')) === "They're ready", `${what}: the dot says "They're ready"`);
    must(await b.locator('#bg-next-waiting').isDisabled(), `${what}: the one who pressed first waits on a greyed NEXT`);
    same(before, await cardBoxes(a), `${what}, the dot appearing`);
    same(beforeB, await cardBoxes(b), `${what}, NEXT pressed`);
    same(playing, await boxes(a), `${what}, the other ready`);
    await a.screenshot({ path: path.join(OUT, `${vp.name}-unlimited-they-are-ready.png`) });
    await b.screenshot({ path: path.join(OUT, `${vp.name}-unlimited-waiting.png`) });

    await a.click('#bg-action-ready');
    await a.waitForSelector('#bg-game-result', { state: 'detached', timeout: 20000 });
    await sleep(1400);
    same(playing, await boxes(a), `${what}, the next game`);
    log(`ok: ${what}`);
  } finally {
    await ca.close();
    await cb.close();
  }
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const failures = [];
  const rooms = arrange();
  try {
    for (const [i, vp] of SCREENS.entries()) {
      const runs = [
        () => unlimitedAgainstSage(browser, vp, rooms[i]),
        () => matchAgainstSage(browser, vp),
        () => twoPeople(browser, vp),
      ];
      const results = await Promise.allSettled(runs.map((f) => f()));
      for (const r of results) if (r.status === 'rejected') failures.push(r.reason.message);
    }
  } finally {
    await browser.close();
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  log(`between games: all good (screenshots in ${OUT})`);
})().catch((e) => { console.error(e); process.exit(1); });
