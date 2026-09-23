/**
 * The Elm landing pages, end to end.
 *
 * 1. Screenshots of the home board and CREATE GAME's dialog, phone and
 *    desktop; the removed games' old links redirect home
 * 2. The home page is one board with the four ways in on it, nothing
 *    scrolls sideways at either width, and the dialog opens over it
 *    without leaving the page
 * 3. A full create -> play click-through: Alice creates a backgammon game and
 *    lands in the waiting room, Bob opens the invite link and types a name,
 *    and both end up at the board
 * 4. Coming home with a game open: the list of games to resume is over the
 *    board, closes in one tap, stays a tap away in the bar, and takes Alice
 *    back to the table
 *
 * Run with the server up:  node playwright/test-spa-landing/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, openCreateDialog, createGame, joinByLink } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/test-spa-landing';
const PHONE = { width: 390, height: 844 };
const DESKTOP = { width: 1280, height: 900 };
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const watch = (page, who, errors) => {
  page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
  });
};

async function shots(browser, viewport, tag, errors) {
  const context = await browser.newContext({ viewport });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  try {
    const page = await context.newPage();
    watch(page, tag, errors);

    await page.goto(`${BASE}/`);
    await page.waitForSelector('#home-menu #start-game');
    // The board's checkers animate in; let them settle on a frame.
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${SHOTS}/${tag}-01-home.png`, fullPage: true });

    // The home page is the board with the four ways in laid on it.
    const checkers = await page.locator('.home-board .checker').count();
    if (checkers !== 30) throw new Error(`the home board shows ${checkers} checkers, not 30`);
    const menu = (await page.textContent('#home-menu')).replace(/\s+/g, ' ').trim();
    for (const entry of ['CREATE GAME', 'JOIN GAME', 'PUZZLES', 'ANALYSIS']) {
      if (!menu.includes(entry)) throw new Error(`the menu reads "${menu}", with no ${entry}`);
    }
    if (menu.includes('TACTICS')) throw new Error(`the menu still promises TACTICS: "${menu}"`);
    // PUZZLES is a way in, not a promise: it opens the practice home
    // without a page load, and the board is still a tap away.
    await page.click('#puzzles');
    await page.waitForSelector('#puzzles-hub');
    if (new URL(page.url()).pathname !== '/puzzles') throw new Error(`PUZZLES landed on ${page.url()}`);
    await page.goBack();
    await page.waitForSelector('#home-menu #start-game');
    // Nothing scrolls sideways at either width.
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    if (overflow > 0) throw new Error(`the home page scrolls sideways by ${overflow}px`);

    // CREATE GAME opens its dialog over the board: no page load, and the
    // board is still behind it.
    await page.click('#start-game');
    await page.waitForSelector('#create-modal #create-name');
    await page.waitForSelector('#create-mode');
    await page.waitForSelector('#create-clock');
    if (new URL(page.url()).pathname !== '/') throw new Error(`the dialog navigated to ${page.url()}`);
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${SHOTS}/${tag}-02-create.png`, fullPage: true });
    await page.click('#close-create');
    await page.waitForSelector('#create-modal', { state: 'detached' });

    // A game's own page is the same home board (it is the one game).
    await page.goto(`${BASE}/backgammon`);
    await page.waitForSelector('#home-menu #start-game');

    // The games that were removed: their old links land home.
    for (const old of ['/poker', '/go?game=123456', '/chess/123456?t=secret']) {
      await page.goto(`${BASE}${old}`);
      await page.waitForSelector('#home-menu #start-game');
      if (new URL(page.url()).pathname !== '/') throw new Error(`${old} landed on ${page.url()}`);
    }
    log(`${tag} screenshots done`);
  } finally {
    await context.close();
  }
}

async function clickThrough(browser, errors) {
  const context = await browser.newContext({ viewport: DESKTOP });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  // A seat is held by the browser's guest cookie, so the two players are
  // two browsers: a second page in Alice's context is Alice, and the room
  // refuses her a second seat.
  const bobContext = await browser.newContext({ viewport: DESKTOP });
  await bobContext.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  try {
    const alice = await context.newPage();
    watch(alice, 'alice', errors);

    // Validation is inline and does not leave the page.
    await openCreateDialog(alice);
    await alice.click('#create-game');
    await alice.waitForSelector('#form-error');
    if (new URL(alice.url()).pathname !== '/') throw new Error(`the empty name navigated to ${alice.url()}`);
    log('empty name rejected inline');
    await alice.click('#close-create');

    const game = await createGame(alice, { name: 'Alice', mode: 'match3', clock: 'bg3' });

    // The waiting room: her seat, the invite link and the code.
    await alice.waitForSelector('#game-code');
    const gameId = (await alice.textContent('#game-code')).trim();
    if (gameId !== game.gameId) throw new Error(`the code reads ${gameId}, the URL says ${game.gameId}`);
    const seatPath = new URL(alice.url()).pathname;
    if (seatPath !== `/backgammon/${game.gameId}`) throw new Error(`creator landed at ${seatPath}`);
    if (new URL(alice.url()).searchParams.get('t')) throw new Error('a seat URL must carry no token');
    const summary = await alice.textContent('#setup-summary');
    if (!/Match to 3/.test(summary) || !/3 min/.test(summary))
      throw new Error(`waiting room summary reads "${summary}"`);
    await alice.screenshot({ path: `${SHOTS}/desktop-04-waiting.png`, fullPage: true });
    log(`game ${gameId} created; waiting room shown`);

    const bob = await bobContext.newPage();
    watch(bob, 'bob', errors);
    const seat = await joinByLink(bob, game.inviteUrl, 'Bob');
    if (!/Match to 3/.test(seat.summary)) throw new Error(`invite summary reads "${seat.summary}"`);

    await alice.waitForSelector('.checker', { timeout: 20000 });
    await bob.waitForSelector('.checker', { timeout: 20000 });
    await alice.waitForTimeout(500);
    await alice.screenshot({ path: `${SHOTS}/desktop-06-table.png` });
    if (new URL(bob.url()).pathname !== `/backgammon/${gameId}`)
      throw new Error(`joiner landed at ${bob.url()}`);
    log('both players at the board: CREATE -> PLAY OK');

    // Alice goes home. Her browser holds a seat in an unfinished game, so
    // the home page opens on the list of games she can resume.
    await alice.goto(`${BASE}/`);
    await alice.waitForSelector('#resume-modal');
    const row = alice.locator(`#resume-${gameId}`);
    const rowText = (await row.textContent()).replace(/\s+/g, ' ').trim();
    // With a clock, the row shows the two times (as of the room's last
    // step, the running one counting down) rather than the preset's name.
    if (!/vs Bob/.test(rowText) || !/Match to 3/.test(rowText) || !/\d+:\d\d \/ \d+:\d\d/.test(rowText))
      throw new Error(`the resume row reads "${rowText}"`);
    if (!/(Your|Their) move/.test(rowText)) throw new Error(`the resume row says nothing about whose move: "${rowText}"`);
    await alice.screenshot({ path: `${SHOTS}/desktop-07-resume.png`, fullPage: true });

    // A tap on the backdrop closes it; the bar keeps the way back.
    await alice.mouse.click(8, 8);
    await alice.waitForSelector('#resume-modal', { state: 'detached' });
    const note = (await alice.textContent('#resume-games')).trim();
    if (note !== 'REJOIN 1 GAME') throw new Error(`the bar reads "${note}"`);
    await alice.click('#resume-games');
    await alice.waitForSelector('#resume-modal');
    await alice.click(`#resume-${gameId}`);
    await alice.waitForSelector('.checker', { timeout: 20000 });
    if (new URL(alice.url()).pathname !== `/backgammon/${gameId}`)
      throw new Error(`resuming landed at ${alice.url()}`);
    log('home -> LIVE GAMES -> back at the table: RESUME OK');

    // The same list on a phone, upright and sideways: it must fit without
    // the page scrolling sideways, and the bar's button must stay in the
    // bar. Same context, so the same guest holds the seat.
    for (const [tag, viewport] of [
      ['phone-390', { width: 390, height: 844 }],
      ['phone-320', { width: 320, height: 568 }],
      ['landscape-844', { width: 844, height: 390 }],
    ]) {
      const small = await context.newPage();
      watch(small, tag, errors);
      await small.setViewportSize(viewport);
      await small.goto(`${BASE}/`);
      await small.waitForSelector('#resume-modal');
      await small.waitForTimeout(300);
      await small.screenshot({ path: `${SHOTS}/${tag}-07-resume.png` });
      const wide = await small.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth
      );
      if (wide > 0) throw new Error(`${tag}: the resume list makes the page ${wide}px too wide`);
      await small.mouse.click(4, 4);
      await small.waitForSelector('#resume-modal', { state: 'detached' });
      const plate = await small.locator('#resume-games').boundingBox();
      const bar = await small.locator('.player-bar.is-me').boundingBox();
      if (!plate || !bar || plate.y < bar.y || plate.y + plate.height > bar.y + bar.height + 1)
        throw new Error(`${tag}: the REJOIN plate is not inside the bar`);
      await small.screenshot({ path: `${SHOTS}/${tag}-08-home-with-games.png` });
      await small.close();
    }
    log('resume list fits on a phone, upright and sideways');

    // Bob, with his game open too, but told through a fresh visitor's eyes:
    // a browser holding no seat sees no list and no button.
    const nobody = await bobContext.browser().newContext({ viewport: DESKTOP });
    try {
      const stranger = await nobody.newPage();
      await stranger.goto(`${BASE}/`);
      await stranger.waitForSelector('#home-menu #start-game');
      await stranger.waitForTimeout(600);
      if (await stranger.locator('#resume-modal').count()) throw new Error('a stranger was offered games to resume');
      if (await stranger.locator('#resume-games').count()) throw new Error('a stranger has a GAMES ON button');
    } finally {
      await nobody.close();
    }
  } finally {
    await context.close();
    await bobContext.close();
  }
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  try {
    await shots(browser, PHONE, 'phone', errors);
    await shots(browser, DESKTOP, 'desktop', errors);
    await clickThrough(browser, errors);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('SPA LANDING OK');
  } catch (e) {
    console.error('SPA LANDING FAILED:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
