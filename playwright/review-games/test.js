/**
 * Drives both games into play and captures the in-game screens for visual
 * review, at desktop and phone widths. Run with the server up:
 *   node playwright/review-games/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const OUT = process.argv[2] || 'playwright/screenshots/review-games';
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

async function lobby(context, slug, format, clock) {
  const p1 = await context.newPage();
  await p1.goto(`${BASE}/${slug}`);
  await p1.waitForSelector('[data-phx-main].phx-connected');
  await p1.fill('input[name="player_name"]', 'Alice');
  await p1.click('#create-game');
  await p1.waitForSelector(`#format-${format}`);
  const gameId = new URL(p1.url()).searchParams.get('game');
  const p2 = await context.newPage();
  await p2.goto(`${BASE}/${slug}?game=${gameId}`);
  await p2.waitForSelector('[data-phx-main].phx-connected');
  await sleep(400);
  await p2.fill('input[name="player_name"]', 'Bob');
  await p2.click('#join-game');
  await p2.waitForSelector(`#format-${format}`);
  await p1.click(`#format-${format}`);
  await p2.click(`#format-${format}`);
  if (clock) { await p1.click(`#clock-${clock}`); await p2.click(`#clock-${clock}`); }
  await p1.waitForSelector('text=Both picked');
  await p1.click('#start-game');
  await p1.waitForURL(`**/${slug}/${gameId}**`);
  await p2.waitForURL(`**/${slug}/${gameId}**`);
  return { p1, p2, gameId };
}

async function tilt(context, tag) {
  const { p1, p2 } = await lobby(context, 'tilt', 'short', null);
  const cards = (page) => page.locator('button[class*="w-[18%]"]:not([disabled])');
  await cards(p1).first().waitFor({ timeout: 20000 });
  await sleep(600);
  await p1.screenshot({ path: `${OUT}/${tag}-tilt-01-dealt.png` });
  // Play hands until the shop appears (short format: 4 hands); snapshot the reveal on hand two.
  for (let hand = 0; hand < 4; hand++) {
    for (const page of [p1, p2]) {
      await cards(page).first().waitFor({ timeout: 20000 });
      await cards(page).nth(0).click();
      await cards(page).nth(1).click();
      await page.click('button:has-text("Play")');
    }
    if (hand === 1) {
      await sleep(1000);
      await p1.screenshot({ path: `${OUT}/${tag}-tilt-02a-reveal-1s.png` });
      await sleep(2000);
      await p1.screenshot({ path: `${OUT}/${tag}-tilt-02b-reveal-3s.png` });
      await sleep(2000);
      await p1.screenshot({ path: `${OUT}/${tag}-tilt-02c-reveal-5s.png` });
      await sleep(2500);
    } else {
      await sleep(7500);
    }
  }
  await p1.waitForSelector('text=Command Center', { timeout: 30000 }).catch(() => {});
  await sleep(800);
  await p1.screenshot({ path: `${OUT}/${tag}-tilt-03-shop.png`, fullPage: true });
  log(`${tag}: tilt captured`);
  await p1.close(); await p2.close();
}

async function backgammon(context, tag) {
  const { p1, p2 } = await lobby(context, 'backgammon', 'match5', 'rapid');
  const source = '.bg-point.source';
  await Promise.race([p1.waitForSelector(source, { timeout: 20000 }), p2.waitForSelector(source, { timeout: 20000 })]);
  const mover = (await p1.locator(source).count()) > 0 ? p1 : p2;
  const waiter = mover === p1 ? p2 : p1;
  await sleep(600);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-01-to-move.png` });
  await mover.locator(source).first().click();
  await sleep(300);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-02-selected.png` });
  await mover.locator('.bg-point.target, [title="Borne off"]:has(.ghost)').first().click();
  await sleep(800);
  // finish the turn
  // Stage the rest of the turn: select a source, wait for its destinations, click one.
  for (let i = 0; i < 4; i++) {
    const src = mover.locator(source);
    if ((await src.count()) === 0) break;
    await src.first().click();
    const target = mover.locator('.bg-point.target, [title="Borne off"]:has(.ghost)');
    try { await target.first().waitFor({ timeout: 3000 }); } catch (_) { break; }
    await target.first().click();
    await mover.waitForFunction(() => !document.querySelector('.bg-point.selected'), null, { timeout: 5000 });
    await sleep(400);
  }
  await mover.screenshot({ path: `${OUT}/${tag}-bg-02b-staged.png` });
  await mover.waitForSelector('button:has-text("PLAY")', { timeout: 10000 });
  await mover.click('button:has-text("PLAY")');
  await waiter.waitForSelector('button:has-text("DOUBLE")', { timeout: 15000 });
  await waiter.screenshot({ path: `${OUT}/${tag}-bg-03-roll-or-double.png` });
  await waiter.click('button:has-text("DOUBLE")');
  await mover.waitForSelector('button:has-text("TAKE")', { timeout: 10000 });
  await sleep(300);
  await mover.screenshot({ path: `${OUT}/${tag}-bg-04-double-offered.png` });
  await mover.click('button:has-text("TAKE")');
  await waiter.waitForSelector('button:has-text("ROLL")', { timeout: 10000 });
  await waiter.click('button:has-text("ROLL")');
  await sleep(800);
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
    try { await tilt(context, tag); } catch (e) { failed = true; console.error(`${tag} tilt: ${e.message}`); }
    try { await backgammon(context, tag); } catch (e) { failed = true; console.error(`${tag} backgammon: ${e.message}`); }
    await context.close();
  }
  await browser.close();
  process.exitCode = failed ? 1 : 0;
})();
