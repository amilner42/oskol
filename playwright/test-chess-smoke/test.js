/**
 * Smoke test for chess on the bespoke board, with a blitz clock.
 *
 * 1. /chess -> create game, second player joins via invite link
 * 2. Both see a full 8x8 board; White at the bottom for Alice, Black for Bob
 * 3. Tapping e2 shows destination hints; tapping e4 plays the move on both
 *    boards; Black replies e5
 * 4. Resign is offered, clocks render, and the phone layout needs no scroll
 *
 * Run with the server up:  node playwright/test-chess-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-chess-smoke';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const sq = (name) => `[data-square="${name}"]`;

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/chess`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#clock-blitz');
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/chess?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/chess/${gameId}**`);
    await p2.waitForURL(`**/chess/${gameId}**`);
    log('Both players on the game page');

    // The full board, oriented per seat: White bottom for Alice.
    await p1.waitForSelector('.chess-board', { timeout: 20000 });
    await p2.waitForSelector('.chess-board', { timeout: 20000 });
    for (const [page, who, topLeft] of [[p1, 'p1', 'a8'], [p2, 'p2', 'h1']]) {
      const squares = await page.locator('.chess-sq').count();
      if (squares !== 64) throw new Error(`${who}: expected 64 squares, saw ${squares}`);
      const pieces = await page.locator('.chess-piece').count();
      if (pieces !== 32) throw new Error(`${who}: expected 32 pieces, saw ${pieces}`);
      const first = await page.locator('.chess-sq').first().getAttribute('data-square');
      if (first !== topLeft) throw new Error(`${who}: top-left square is ${first}, expected ${topLeft}`);
    }
    if ((await p1.locator('button:has-text("RESIGN")').count()) !== 1) throw new Error('White must be able to resign');
    if ((await p2.locator('button:has-text("RESIGN")').count()) !== 1) throw new Error('Black must be able to resign');
    await p2.waitForFunction(() => /WAITING FOR ALICE/.test(document.body.textContent), null, { timeout: 10000 });
    const clockText = await p1.locator('.clock-chip').allTextContents();
    if (!clockText.some((t) => /\d+:\d\d/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);

    await p1.screenshot({ path: `${SHOTS}/01-white-to-move.png` });
    await p2.screenshot({ path: `${SHOTS}/02-black-waiting.png` });

    // Tap the e2 pawn: destination hints appear; tap e4 to play.
    await p1.click(sq('e2'));
    await p1.waitForSelector('.chess-hint', { timeout: 5000 });
    const hints = await p1.locator('.chess-hint').count();
    if (hints !== 2) throw new Error(`expected 2 destination hints for e2, saw ${hints}`);
    await p1.screenshot({ path: `${SHOTS}/03-e2-selected.png` });
    await p1.click(sq('e4'));
    await p2.waitForSelector(`${sq('e4')} .chess-piece`, { timeout: 20000 });
    log('e4 played and visible to Black');

    // Black replies e5; White sees it.
    await p2.click(sq('e7'));
    await p2.waitForSelector('.chess-hint', { timeout: 5000 });
    await p2.click(sq('e5'));
    await p1.waitForSelector(`${sq('e5')} .chess-piece`, { timeout: 20000 });
    await p1.screenshot({ path: `${SHOTS}/04-after-e4-e5.png` });
    log('e4 e5 played');

    // Phone width: one screen, no scrolling, board and actions usable.
    const phone = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await phone.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const m1 = await phone.newPage();
    watch(m1, 'phone');
    await m1.goto(p1.url());
    await m1.waitForSelector('.chess-board', { timeout: 20000 });
    await sleep(400);
    const scroll = await m1.evaluate(() => ({
      body: document.body.scrollHeight - window.innerHeight,
    }));
    if (scroll.body > 1) throw new Error(`phone page scrolls by ${scroll.body}px`);
    await m1.screenshot({ path: `${SHOTS}/05-phone-white.png` });
    await m1.close();
    await phone.close();

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('SMOKE OK');
  } catch (e) {
    await Promise.all(context.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${i}.png` }).catch(() => {})));
    console.error('SMOKE FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
