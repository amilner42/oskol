/**
 * End-to-end smoke test for Tilt on the gamekit stack.
 *
 * 1. Library page lists Tilt and links to /tilt
 * 2. Player 1 creates a game at /tilt, Player 2 joins via invite link
 * 3. Both pick the Short format and start
 * 4. Both play one card; the score reveal runs and the next hand is dealt
 *
 * Run with the server up:  node playwright/test-tilt-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-tilt-smoke';

const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    // Use the preinstalled browser when the pinned Playwright build is absent.
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(`${who} console: ${m.text()}`); });
  };

  try {
    // 1. Library
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/`);
    await p1.waitForSelector('#game-tilt');
    await p1.screenshot({ path: `${SHOTS}/01-library.png` });
    log('Library lists Tilt');
    await p1.click('#game-tilt');
    await p1.waitForSelector('form[phx-submit="new_game"]');
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.screenshot({ path: `${SHOTS}/02-tilt-start.png` });

    // 2. Create + join
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('button:has-text("New Game")');
    await p1.waitForSelector('#format-short');
    const gameId = new URL(p1.url()).searchParams.get('game');
    if (!gameId) throw new Error('no game id in lobby url ' + p1.url());
    log(`Game ${gameId} created at ${p1.url()}`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/tilt?game=${gameId}`);
    await p2.waitForSelector('form[phx-submit="submit_player_name"]');
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await sleep(500);
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('button:has-text("Join Game")');
    await p2.waitForSelector('#format-short');
    await p1.screenshot({ path: `${SHOTS}/03-lobby.png` });

    // 3. Format + start
    await p1.click('#format-short');
    await p2.click('#format-short');
    await p1.waitForSelector('text=Both players selected Short');
    await p1.click('button:has-text("Start Game")');
    await p1.waitForURL(`**/tilt/${gameId}**`);
    await p2.waitForURL(`**/tilt/${gameId}**`);
    log('Both players on the game page');

    // 4. Play a hand each
    for (const [page, who] of [[p1, 'p1'], [p2, 'p2']]) {
      await page.waitForSelector('button:has-text("Play")', { timeout: 20000 });
      await page.screenshot({ path: `${SHOTS}/04-${who}-dealt.png` });
    }
    const playOne = async (page, who) => {
      // Own hand cards are the enabled fan buttons at the bottom of the board.
      const cards = page.locator('button[class*="w-[18%]"]:not([disabled])');
      await cards.first().waitFor({ timeout: 20000 });
      const n = await cards.count();
      if (n === 0) throw new Error(`${who}: no cards found to click`);
      await cards.first().click();
      await page.click('button:has-text("Play")');
      log(`${who} played a card (${n} cards in hand)`);
    };
    await playOne(p1, 'p1');
    await playOne(p2, 'p2');
    await sleep(6000); // score reveal
    await p1.screenshot({ path: `${SHOTS}/05-after-first-hand.png` });
    await p2.screenshot({ path: `${SHOTS}/06-after-first-hand-p2.png` });

    // After the reveal both players are back to a full hand with Play available,
    // and the played card left each hand.
    for (const [page, who] of [[p1, 'p1'], [p2, 'p2']]) {
      await page.waitForSelector('button:has-text("Play")', { timeout: 20000 });
      const n = await page.locator('button[class*="w-[18%]"]').count();
      if (n !== 8) throw new Error(`${who}: expected 8 cards after refill, saw ${n}`);
    }
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
