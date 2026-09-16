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
    for (const entry of ['CREATE GAME', 'JOIN GAME', 'TACTICS', 'ANALYSIS']) {
      if (!menu.includes(entry)) throw new Error(`the menu reads "${menu}", with no ${entry}`);
    }
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

    const bob = await context.newPage();
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
  } finally {
    await context.close();
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
