/**
 * Smoke test for backgammon on the generic renderer, with a blitz clock.
 *
 * 1. /backgammon -> create game, second player joins via invite link
 * 2. Both pick "Single game" and the Blitz clock, start
 * 3. The player to move sees move buttons; clicking one moves a checker
 * 4. Clocks render and the mover's clock is running
 *
 * Run with the server up:  node playwright/test-backgammon-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = 'playwright/screenshots/test-backgammon-smoke';
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
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error') errors.push(`${who} console: ${m.text()}`); });
  };

  try {
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#create-game');
    await p1.waitForSelector('#format-single');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await sleep(500);
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p2.waitForSelector('#format-single');

    await p1.click('#format-single');
    await p2.click('#format-single');
    await p1.click('#clock-blitz');
    await p1.waitForSelector('text=Agree on a time control');
    await p2.click('#clock-blitz');
    await p1.waitForSelector('text=Both picked Single game');
    await p1.screenshot({ path: `${SHOTS}/01-lobby.png` });
    await p1.click('button:has-text("Start Game")');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    log('Both players on the game page');

    // Generic renderer: whoever moves first has "→" move buttons.
    const moveButton = 'button:has-text("→")';
    await Promise.race([
      p1.waitForSelector(moveButton, { timeout: 20000 }),
      p2.waitForSelector(moveButton, { timeout: 20000 }),
    ]);
    const mover = (await p1.locator(moveButton).count()) > 0 ? p1 : p2;
    const waiter = mover === p1 ? p2 : p1;
    await mover.screenshot({ path: `${SHOTS}/02-mover.png` });
    await waiter.screenshot({ path: `${SHOTS}/03-waiter.png` });

    const checkersBefore = await mover.locator('button[title^="w"], button[title^="b"]').count();
    if (checkersBefore !== 30) throw new Error(`expected 30 checkers rendered, saw ${checkersBefore}`);
    const waiterBody = await waiter.textContent('body');
    if (!/Waiting for (Alice|Bob)/.test(waiterBody)) throw new Error('waiting player should see whose turn it is');
    if ((await waiter.locator(moveButton).count()) !== 0) throw new Error('waiting player must not see move buttons');
    if (!waiterBody.includes('Resign')) throw new Error('resign should always be offered');
    const clockText = await mover.locator('.font-mono .tabular-nums').allTextContents();
    if (!clockText.some((t) => /^\d+:\d\d$/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);

    const before = await mover.locator(moveButton).count();
    await mover.locator(moveButton).first().click();
    await sleep(1500);
    await mover.screenshot({ path: `${SHOTS}/04-after-move.png` });
    const after = await mover.locator(moveButton).count();
    log(`moves offered before: ${before}, after: ${after}`);
    if (after === before) throw new Error('the move did not change the legal actions');

    // Play out the rest of the mover's dice, then the other player should be asked to roll.
    for (let i = 0; i < 4 && (await mover.locator(moveButton).count()) > 0; i++) {
      await mover.locator(moveButton).first().click();
      await sleep(800);
    }
    await waiter.waitForSelector('button:has-text("Roll dice")', { timeout: 10000 });
    await waiter.click('button:has-text("Roll dice")');
    await sleep(1000);
    await waiter.screenshot({ path: `${SHOTS}/05-rolled.png` });
    const dice = await waiter.locator('.rounded-md.bg-white').count();
    if (dice < 2) throw new Error(`expected dice tokens after rolling, saw ${dice}`);

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
