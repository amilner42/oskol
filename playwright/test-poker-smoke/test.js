/**
 * Smoke test for the poker table.
 *
 * 1. /poker -> the creator picks a cash game at 2/5 and creates it
 * 2. The opponent opens the link and joins; both land on the table
 * 3. Each player sees two faces of their own and two backs for the other
 * 4. The player to act folds; the hand is over and the next one is dealt
 * 5. Preflop the button calls, the big blind checks, a flop appears
 *
 * Run with the server up:  node playwright/test-poker-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-poker-smoke';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const context = await browser.newContext({ viewport: { width: 420, height: 860 } });
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
    await p1.goto(`${BASE}/poker`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#format-cash');
    await p1.click('#choice-stake-2-5');
    await p1.click('#clock-none');
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/poker?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await p2.waitForSelector('text=2 / 5');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/poker/${gameId}**`);
    await p2.waitForURL(`**/poker/${gameId}**`);
    log('Both players at the table');

    await p1.waitForSelector('#actions', { timeout: 20000 });
    await p2.waitForSelector('#actions', { timeout: 20000 });
    await sleep(300);
    await p1.screenshot({ path: `${SHOTS}/01-alice.png` });
    await p2.screenshot({ path: `${SHOTS}/02-bob.png` });

    // Hidden information on screen: two faces of my own, two backs for them.
    for (const [page, who] of [[p1, 'Alice'], [p2, 'Bob']]) {
      const faces = await page.locator('[data-seat] [data-card]:not([data-card="back"])').count();
      const backs = await page.locator('[data-card="back"]').count();
      if (faces !== 2 || backs !== 2) throw new Error(`${who} sees ${faces} faces and ${backs} backs`);
    }
    const hand1 = await p1.locator('#hand-number').textContent();

    // Whoever is to act folds: the hand ends, the pot goes across.
    const actor = (await p1.locator('button:has-text("FOLD")').count()) > 0 ? p1 : p2;
    const other = actor === p1 ? p2 : p1;
    if ((await other.locator('button:has-text("FOLD")').count()) !== 0) throw new Error('both players think they are to act');
    await actor.click('button:has-text("FOLD")');
    await other.waitForSelector('#banner', { timeout: 10000 });
    const banner = await other.locator('#banner').textContent();
    if (!/WINS/.test(banner)) throw new Error(`expected a winner banner, saw: ${banner}`);
    await other.screenshot({ path: `${SHOTS}/03-hand-over.png` });

    // The next hand is dealt (by the button, automatically).
    await p1.waitForFunction((h) => document.querySelector('#hand-number')?.textContent !== h, hand1, { timeout: 15000 });
    log('Next hand dealt');

    // Button calls, big blind checks: a flop appears for both.
    const caller = (await p1.locator('button:has-text("CALL")').count()) > 0 ? p1 : p2;
    const bigBlind = caller === p1 ? p2 : p1;
    await caller.click('button:has-text("CALL")');
    await bigBlind.waitForSelector('button:has-text("CHECK")', { timeout: 10000 });
    await bigBlind.click('button:has-text("CHECK")');
    await p1.waitForFunction(() => document.querySelectorAll('#board [data-card]:not([data-card="back"])').length === 3, null, { timeout: 10000 });
    await p2.waitForFunction(() => document.querySelectorAll('#board [data-card]:not([data-card="back"])').length === 3, null, { timeout: 10000 });
    await p1.screenshot({ path: `${SHOTS}/04-flop.png` });
    log('Flop dealt to both');

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
