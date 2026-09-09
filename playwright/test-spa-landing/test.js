/**
 * The Elm landing pages, end to end.
 *
 * 1. Screenshots of the library and a game's start page, phone and desktop
 * 2. The phone library really is the 2x2 tile grid, the desktop one the cabinets
 * 3. A full create -> play click-through: Alice creates a backgammon game and
 *    lands in the waiting room, Bob opens the invite link and types a name,
 *    and both end up at the board
 *
 * Run with the server up:  node playwright/test-spa-landing/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
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
    await page.waitForSelector('#game-library a', { state: 'attached' });
    // The art reel is a CSS animation; let it settle on a frame.
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${SHOTS}/${tag}-01-library.png`, fullPage: true });

    const tilesShown = await page.locator('#game-tiles').isVisible();
    const cabinetsShown = await page.locator('#game-library').isVisible();
    if (tag === 'phone' && !(tilesShown && !cabinetsShown))
      throw new Error('a phone must get the 2x2 tiles and not the cabinets');
    if (tag === 'desktop' && !(cabinetsShown && !tilesShown))
      throw new Error('a desktop must get the cabinets and not the tiles');
    const tiles = await page.locator('#game-tiles a.game-tile').count();
    if (tiles !== 4) throw new Error(`expected 4 game tiles, saw ${tiles}`);

    // Client-side navigation to a game page: no page load.
    await page.click(tag === 'phone' ? '#game-tile-backgammon' : '#game-backgammon');
    await page.waitForSelector('#create-game');
    await page.waitForSelector('#rules');
    if (new URL(page.url()).pathname !== '/backgammon')
      throw new Error(`expected /backgammon, saw ${page.url()}`);
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${SHOTS}/${tag}-02-backgammon.png`, fullPage: true });

    await page.goto(`${BASE}/poker`);
    await page.waitForSelector('#format-cash');
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${SHOTS}/${tag}-03-poker.png`, fullPage: true });
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
    await alice.goto(`${BASE}/backgammon`);
    await alice.waitForSelector('#create-name');

    // Validation is inline and does not leave the page.
    await alice.click('#create-game');
    await alice.waitForSelector('#form-error');
    log('empty name rejected inline');

    await alice.fill('input[name="player_name"]', 'Alice');
    await alice.click('#format-match3');
    await alice.click('#clock-blitz');
    await alice.click('#create-game');

    // The waiting room: her seat, the invite link and the code.
    await alice.waitForSelector('#game-code');
    await alice.waitForSelector('#share-link');
    const gameId = (await alice.textContent('#game-code')).trim();
    const path = new URL(alice.url()).pathname;
    if (path !== `/backgammon/${gameId}`) throw new Error(`creator landed at ${path}`);
    if (!new URL(alice.url()).searchParams.get('t')) throw new Error('creator has no seat token');
    const summary = await alice.textContent('#setup-summary');
    if (!/Match to 3/.test(summary) || !/Blitz clock/.test(summary))
      throw new Error(`waiting room summary reads "${summary}"`);
    await alice.screenshot({ path: `${SHOTS}/desktop-04-waiting.png`, fullPage: true });
    log(`game ${gameId} created; waiting room shown`);

    const bob = await context.newPage();
    watch(bob, 'bob', errors);
    await bob.goto(`${BASE}/backgammon?game=${gameId}`);
    await bob.waitForSelector('#join-game');
    const challenge = await bob.textContent('#setup-summary');
    if (!/Match to 3/.test(challenge)) throw new Error(`invite summary reads "${challenge}"`);
    await bob.screenshot({ path: `${SHOTS}/desktop-05-invite.png`, fullPage: true });
    await bob.fill('input[name="player_name"]', 'Bob');
    await bob.click('#join-game');

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
