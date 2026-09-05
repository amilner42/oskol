/**
 * Smoke test for go on the generic renderer, with a rapid clock, at desktop
 * and phone widths.
 *
 * 1. /go -> create a 9x9 game, second player joins via invite link
 * 2. Black sees the board grid and "Place a stone"; white only waits
 * 3. Placing a stone: pick the action, click an intersection, confirm
 * 4. The stone appears on both boards; pass works; clocks render
 *
 * Run with the server up:  node playwright/test-go-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-go-smoke';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run(browser, tag, viewport, errors) {
  const context = await browser.newContext({ viewport });
  // External fonts are blocked in sandboxes and would stall the load event.
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${tag} ${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${tag} ${who} console: ${m.text()}`);
    });
  };

  try {
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/go`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#format-9x9');
    await p1.click('#clock-rapid');
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`${tag}: game ${gameId} created`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/go?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await sleep(300);
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/go/${gameId}**`);
    await p2.waitForURL(`**/go/${gameId}**`);
    log(`${tag}: both players on the game page`);

    // Black (the creator) is to move; white waits with only Resign.
    await p1.waitForSelector('button:has-text("Place a stone")', { timeout: 20000 });
    await p2.waitForSelector('button:has-text("Resign")', { timeout: 20000 });
    const points = await p1.locator('[title^="p"][title*="-"]').count();
    if (points !== 81) throw new Error(`expected 81 board intersections, saw ${points}`);
    if ((await p2.locator('button:has-text("Place a stone")').count()) !== 0)
      throw new Error('the waiting player must not be offered a placement');
    try {
      await p2.waitForFunction(() => /WAITING FOR ALICE/.test(document.body.textContent), null, { timeout: 10000 });
    } catch (_) {
      throw new Error('waiting player should see whose turn it is');
    }
    const clockText = await p1.locator('.font-mono .tabular-nums').allTextContents();
    if (!clockText.some((t) => /^\d+:\d\d$/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);
    await p1.screenshot({ path: `${SHOTS}/${tag}-01-black-to-move.png` });
    await p2.screenshot({ path: `${SHOTS}/${tag}-02-white-waiting.png` });

    // Place a stone: choose the action, click an intersection, confirm.
    await p1.click('button:has-text("Place a stone")');
    await p1.click('[title="p4-4"]');
    await p1.screenshot({ path: `${SHOTS}/${tag}-03-point-picked.png` });
    await p1.click('button:has-text("CONFIRM")');
    await p1.waitForSelector('[title="s1"]', { timeout: 10000 });
    await p2.waitForSelector('[title="s1"]', { timeout: 10000 });
    log(`${tag}: black stone placed and visible to both`);

    // White replies, then black passes and the turn comes back to white.
    await p2.waitForSelector('button:has-text("Place a stone")', { timeout: 10000 });
    await p2.click('button:has-text("Place a stone")');
    await p2.click('[title="p2-2"]');
    await p2.click('button:has-text("CONFIRM")');
    await p1.waitForSelector('[title="s2"]', { timeout: 10000 });
    await p1.waitForSelector('button:has-text("Pass")', { timeout: 10000 });
    await p1.click('button:has-text("Pass")');
    await p2.waitForSelector('button:has-text("Place a stone")', { timeout: 10000 });
    await sleep(400);
    await p2.screenshot({ path: `${SHOTS}/${tag}-04-after-pass.png` });
    log(`${tag}: SMOKE OK`);
    await p1.close();
    await p2.close();
  } catch (e) {
    await Promise.all(
      context.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/${tag}-99-failure-${i}.png` }).catch(() => {}))
    );
    throw new Error(`${tag}: ${e.message}`);
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
    await run(browser, 'desktop', { width: 1280, height: 900 }, errors);
    await run(browser, 'phone', { width: 390, height: 844 }, errors);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
  } catch (e) {
    console.error('SMOKE FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
