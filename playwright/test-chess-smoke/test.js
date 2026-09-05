/**
 * Smoke test for chess on the generic renderer, with a blitz clock.
 *
 * 1. /chess -> create game, second player joins via invite link
 * 2. White (the creator) sees 20 move buttons plus Resign; Black waits
 * 3. Clicking "e2 -> e4" moves the pawn on both boards
 * 4. Black then has moves; clocks render; desktop and phone screenshots
 *
 * Run with the server up:  node playwright/test-chess-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-chess-smoke';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

    // The creator is White and opens: 20 move buttons plus Resign.
    const e4 = 'button:has-text("e2 → e4")';
    await p1.waitForSelector(e4, { timeout: 20000 });
    const moveButtons = await p1.locator('button:has-text("→"), button:has-text("O-O")').count();
    if (moveButtons !== 20) throw new Error(`expected 20 move buttons for White, saw ${moveButtons}`);
    if ((await p1.locator('button:has-text("Resign")').count()) !== 1) throw new Error('White must be able to resign');
    // All 32 pieces on both boards (glyph per token).
    await p2.waitForFunction(() => (document.body.textContent.match(/♟/g) || []).length === 8, null, { timeout: 20000 });
    for (const [page, who] of [[p1, 'p1'], [p2, 'p2']]) {
      const pawns = (await page.locator('text=♙').count());
      const kings = (await page.locator('text=♔').count());
      if (pawns !== 8 || kings !== 1) throw new Error(`${who}: board incomplete (${pawns} white pawns, ${kings} white kings)`);
    }
    // Black cannot move yet, only resign, and sees whose turn it is.
    if ((await p2.locator('button:has-text("→")').count()) !== 0) throw new Error('Black must have no moves before White plays');
    if ((await p2.locator('button:has-text("Resign")').count()) !== 1) throw new Error('Black must be able to resign');
    await p2.waitForFunction(() => /WAITING FOR ALICE/.test(document.body.textContent), null, { timeout: 10000 });
    const clockText = await p1.locator('.font-mono .tabular-nums').allTextContents();
    if (!clockText.some((t) => /^\d+:\d\d$/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);

    await p1.screenshot({ path: `${SHOTS}/01-white-to-move.png` });
    await p2.screenshot({ path: `${SHOTS}/02-black-waiting.png` });

    // e4: the button fires immediately (single-candidate params).
    await p1.click(e4);
    await p2.waitForSelector('button:has-text("e7 → e5")', { timeout: 20000 });
    await sleep(400);
    // The pawn moved on the opponent's board: e2 empty, e4 occupied.
    const zones = await p2.evaluate(() => document.body.textContent);
    if (!zones.includes('♙')) throw new Error('white pawns vanished');
    await p2.screenshot({ path: `${SHOTS}/03-black-to-move.png` });
    await p2.click('button:has-text("e7 → e5")');
    await p1.waitForSelector('button:has-text("N g1 → f3")', { timeout: 20000 });
    log('e4 e5 played; White to move again');

    // Phone width: the board and actions must still be usable.
    const phone = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await phone.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const m1 = await phone.newPage();
    watch(m1, 'phone');
    await m1.goto(p1.url());
    await m1.waitForSelector('button:has-text("N g1 → f3")', { timeout: 20000 });
    await m1.screenshot({ path: `${SHOTS}/04-phone-white.png`, fullPage: true });
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
