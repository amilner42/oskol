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
  // External fonts are blocked in sandboxes and would stall the load event.
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    // Ignore blocked third-party resources (fonts) in sandboxed runs; app errors still fail the test.
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#create-game');
    await p1.waitForSelector('#format-match3');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await sleep(500);
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p2.waitForSelector('#format-match3');

    await p1.click('#format-match3');
    await p2.click('#format-match3');
    await p1.click('#clock-blitz');
    await p1.waitForSelector('text=Agree on a time control');
    await p2.click('#clock-blitz');
    await p1.waitForSelector('text=Both picked Match to 3');
    await p1.screenshot({ path: `${SHOTS}/01-lobby.png` });
    await p1.click('#start-game');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    log('Both players on the game page');

    // Bespoke board: whoever moves first has selectable source points.
    const source = '.bg-point.source';
    await Promise.race([
      p1.waitForSelector(source, { timeout: 20000 }),
      p2.waitForSelector(source, { timeout: 20000 }),
    ]);
    const mover = (await p1.locator(source).count()) > 0 ? p1 : p2;
    const waiter = mover === p1 ? p2 : p1;
    await mover.screenshot({ path: `${SHOTS}/02-mover.png` });
    await waiter.screenshot({ path: `${SHOTS}/03-waiter.png` });

    const checkers = await mover.locator('.checker').count();
    if (checkers !== 30) throw new Error(`expected 30 checkers on the board, saw ${checkers}`);
    if ((await waiter.locator(source).count()) !== 0) throw new Error('waiting player must not have selectable points');
    const waiterBody = await waiter.textContent('body');
    if (!/WAITING FOR (ALICE|BOB)/.test(waiterBody)) throw new Error('waiting player should see whose turn it is');
    const clockText = await mover.locator('.font-mono .tabular-nums').allTextContents();
    if (!clockText.some((t) => /^\d+:\d\d$/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);

    // Click a source, expect targets, click one: the dice count of unused dice drops.
    const usedBefore = await mover.locator('.die.used').count();
    await mover.locator(source).first().click();
    await mover.waitForSelector('.bg-point.target, [title="Borne off"]:has(.ghost)', { timeout: 5000 });
    await mover.screenshot({ path: `${SHOTS}/04-targets.png` });
    await mover.locator('.bg-point.target, [title="Borne off"]:has(.ghost)').first().click();
    await sleep(1200);
    const usedAfter = await mover.locator('.die.used').count();
    log(`used dice before: ${usedBefore}, after: ${usedAfter}`);
    if (usedAfter <= usedBefore) throw new Error('the move did not consume a die');

    // Finish the turn; the other player then gets ROLL and DOUBLE.
    for (let i = 0; i < 4 && (await mover.locator(source).count()) > 0; i++) {
      await mover.locator(source).first().click();
      await sleep(200);
      await mover.locator('.bg-point.target, [title="Borne off"]:has(.ghost)').first().click();
      await sleep(700);
    }
    await waiter.waitForSelector('button:has-text("ROLL")', { timeout: 10000 });
    if ((await waiter.locator('button:has-text("DOUBLE")').count()) !== 1) throw new Error('doubling should be offered before rolling');
    await waiter.click('button:has-text("ROLL")');
    await sleep(1000);
    await waiter.screenshot({ path: `${SHOTS}/05-rolled.png` });
    const dice = await waiter.locator('.die').count();
    if (dice < 2) throw new Error(`expected dice after rolling, saw ${dice}`);

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
