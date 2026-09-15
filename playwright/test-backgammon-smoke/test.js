/**
 * Smoke test for backgammon, with a 3 minute clock and the game's 12 s delay.
 *
 * 1. / -> CREATE GAME -> the dialog: Match to 3, 3 min; the second player
 *    joins by the invite link (playwright/lib/flows.js does both)
 * 2. The player to move sees selectable points; a tap plays a die
 * 3. Clocks render; the first 12 s of a turn are free
 * 4. PLAY ends the turn; the opponent is offered ROLL and DOUBLE
 *
 * Run with the server up:  node playwright/test-backgammon-smoke/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { createGame, joinByLink } = require('../lib/flows');

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
    // The creator picks everything on the home page, then shares the link.
    const game = await createGame(p1, { name: 'Alice', mode: 'match3', clock: 'bg3' });
    const gameId = game.gameId;
    log(`Game ${gameId} created`);
    await p1.screenshot({ path: `${SHOTS}/01-lobby.png` });

    // The opponent opens the link, types a name, and the game starts.
    const p2 = await context.newPage();
    watch(p2, 'p2');
    const joined = await joinByLink(p2, game.inviteUrl, 'Bob');
    if (!/Match to 3/.test(joined.summary) || !/3 min/.test(joined.summary)) {
      throw new Error(`the invite should say what the game is, said: ${joined.summary}`);
    }
    await p1.waitForURL(`**/backgammon/${gameId}**`);
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
    // The waiter's page may still be joining its channel: wait for its board.
    await waiter.waitForSelector('.checker', { timeout: 20000 });
    if ((await waiter.locator(source).count()) !== 0) throw new Error('waiting player must not have selectable points');
    try {
      await waiter.waitForFunction(() => /WAITING FOR (ALICE|BOB)/.test(document.body.textContent), null, { timeout: 10000 });
    } catch (_) {
      throw new Error('waiting player should see whose turn it is');
    }
    const clockText = await mover.locator('.font-mono .tabular-nums').allTextContents();
    if (!clockText.some((t) => /^\d+:\d\d$/.test(t))) throw new Error(`clocks not rendered: ${clockText}`);
    // 3 minutes each, and the turn's first 12 s are free: nobody's bank has
    // moved yet, and a couple of seconds into the turn it still has not.
    if (!clockText.every((t) => !/^\d+:\d\d$/.test(t) || t === '3:00')) throw new Error(`expected 3:00 each, saw ${clockText}`);
    await sleep(2500);
    const stillFree = await mover.locator('.font-mono .tabular-nums').allTextContents();
    if (!stillFree.every((t) => !/^\d+:\d\d$/.test(t) || t === '3:00')) throw new Error(`the 12 s delay should be free, saw ${stillFree}`);

    // One tap on a source plays it with the next die: a die is spent, at once.
    const usedBefore = await mover.locator('.die.used').count();
    await mover.locator(source).first().click();
    await mover.waitForFunction((n) => document.querySelectorAll('.die.used').length > n, usedBefore, { timeout: 5000 });
    await sleep(600);
    await mover.screenshot({ path: `${SHOTS}/04-played.png` });
    const usedAfter = await mover.locator('.die.used').count();
    log(`used dice before: ${usedBefore}, after: ${usedAfter}`);
    if (usedAfter <= usedBefore) throw new Error('the move did not consume a die');

    // Finish the turn; the other player then gets ROLL and DOUBLE.
    // Stage the rest of the turn: one tap per source spends a die.
    for (let i = 0; i < 4; i++) {
      const src = mover.locator(source);
      if ((await src.count()) === 0) break;
      const used = await mover.locator('.die.used').count();
      await src.first().click();
      try {
        await mover.waitForFunction((n) => document.querySelectorAll('.die.used').length > n, used, { timeout: 3000 });
      } catch (_) { break; }
      await sleep(400);
    }
    // Moves are staged privately; the turn ends with PLAY.
    if ((await waiter.locator('.checker').count()) !== 30) throw new Error('opponent view should not change during staging');
    await mover.waitForSelector('#bg-action-play', { timeout: 10000 });
    await mover.click('#bg-action-play');
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
