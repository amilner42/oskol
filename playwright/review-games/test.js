/**
 * Drives backgammon into play and captures the in-game screens for visual
 * review, at desktop and phone widths. Run with the server up:
 *   node playwright/review-games/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { createGame, joinByLink } = require('../lib/flows');

const OUT = process.argv[2] || 'playwright/screenshots/review-games';
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

async function lobby(context, slug, mode, clock) {
  const p1 = await context.newPage();
  const { gameId, inviteUrl } = await createGame(p1, { name: 'Alice', mode, clock });
  const p2 = await context.newPage();
  await joinByLink(p2, inviteUrl, 'Bob');
  await p1.waitForURL(`**/${slug}/${gameId}**`);
  await p2.waitForURL(`**/${slug}/${gameId}**`);
  return { p1, p2, gameId };
}

async function backgammon(context, tag) {
  const { p1, p2 } = await lobby(context, 'backgammon', 'match5', 'bg5');
  const source = '.bg-point.source';
  await Promise.race([p1.waitForSelector(source, { timeout: 20000 }), p2.waitForSelector(source, { timeout: 20000 })]);
  const mover = (await p1.locator(source).count()) > 0 ? p1 : p2;
  const waiter = mover === p1 ? p2 : p1;
  await sleep(600);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-01-to-move.png` });
  // One tap on a source plays it with the next die.
  await mover.locator(source).first().click();
  await sleep(800);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-02-played.png` });
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
  await mover.screenshot({ path: `${OUT}/${tag}-bg-02b-staged.png` });
  await mover.waitForSelector('#bg-action-play', { timeout: 10000 });
  await mover.click('#bg-action-play');
  await waiter.waitForSelector('button:has-text("DOUBLE")', { timeout: 15000 });
  await waiter.screenshot({ path: `${OUT}/${tag}-bg-03-roll-or-double.png` });
  await waiter.click('button:has-text("DOUBLE")');
  await mover.waitForSelector('button:has-text("TAKE")', { timeout: 10000 });
  await sleep(300);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-04-double-offered.png` });
  await mover.click('button:has-text("TAKE")');
  // The doubler's turn rolls itself once the cube is settled: no button.
  await waiter.waitForSelector('.die', { timeout: 15000 });
  await sleep(1200);
  await waiter.screenshot({ path: `${OUT}/${tag}-bg-05-after-take-rolled.png` });
  log(`${tag}: backgammon captured`);
  await p1.close(); await p2.close();
}

(async () => {
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM || undefined, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  let failed = false;
  for (const [tag, vp] of [['desktop', { width: 1280, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    const context = await browser.newContext({ viewport: vp });
  // External fonts are blocked in sandboxes and would stall the load event.
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    try { await backgammon(context, tag); } catch (e) { failed = true; console.error(`${tag} backgammon: ${e.message}`); }
    await context.close();
  }
  await browser.close();
  process.exitCode = failed ? 1 : 0;
})();
