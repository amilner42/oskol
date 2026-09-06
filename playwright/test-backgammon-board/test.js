/**
 * Classic-board smoke: cube fixture, split centre band, full-height bar,
 * auto-roll.
 *
 * 1. Alice (desktop 1280x900) and Bob (phone 390x844) start a single game.
 * 2. At the start both see one full-height bar and the cube fixture on the
 *    left showing 64.
 * 3. The opening mover plays; the other player then has a real choice:
 *    ROLL on the right half of the board, DOUBLE on the left. They DOUBLE.
 * 4. The responder sees TAKE/DROP on the left half and the cube prominent
 *    at the offered value 2; they TAKE. The cube relocates: bottom of the
 *    rail for the taker, top for the doubler, still showing 2.
 * 5. The doubler's turn now rolls itself -- no ROLL button ever shows --
 *    and play continues.
 * 6. Turns loop until someone is hit, for a checker-on-the-bar screenshot
 *    (best effort: logged, not fatal, if the dice never cooperate).
 *
 * Run with the server up:  node playwright/test-backgammon-board/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = process.env.SHOTS_DIR || 'playwright/screenshots/test-backgammon-board';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SOURCE = '[data-drag-capture]';
const TARGET = '.bg-point:has(.drop-ghost), .bg-tray:has(.drop-ghost)';

async function box(page, selector) {
  const b = await page.locator(selector).first().boundingBox();
  if (!b) throw new Error(`no box for ${selector}`);
  return b;
}

const mid = (b) => ({ x: b.x + b.width / 2, y: b.y + b.height / 2 });

/** Assert a button sits on the given half of the board. */
async function assertHalf(page, selector, half, label) {
  const board = await box(page, '.bg-board');
  const b = await box(page, selector);
  const onLeft = mid(b).x < mid(board).x;
  if ((half === 'left') !== onLeft) throw new Error(`${label}: expected ${selector} on the ${half} half`);
}

/** Tap-play the rest of a turn: sources -> drop-ghost targets, then PLAY.
 * Clicks ROLL if it is offered (cube owner's turns keep the choice). */
async function playFullTurn(page, label) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await page.locator('button:has-text("PLAY")').count()) {
      await page.click('button:has-text("PLAY")');
      await sleep(400);
      return;
    }
    if (await page.locator('button:has-text("ROLL")').count()) {
      await page.click('button:has-text("ROLL")');
      await sleep(500);
      continue;
    }
    if (await page.locator(SOURCE).count()) {
      await page.locator(SOURCE).first().click();
      try {
        await page.locator(TARGET).first().waitFor({ timeout: 2000 });
        await page.locator(TARGET).first().click();
      } catch (_) {}
      await sleep(400);
      continue;
    }
    await sleep(250);
  }
  throw new Error(`${label}: turn did not complete`);
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const desktop = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  for (const c of [desktop, phone]) await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const p1 = await desktop.newPage();
    watch(p1, 'desktop');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('[data-phx-main].phx-connected');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#format-match3'); // the cube plays in match formats
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await phone.newPage();
    watch(p2, 'phone');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await p2.waitForSelector('text=Match to 3');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    const name = (page) => (page === p1 ? 'desktop' : 'phone');

    // The permanent fixtures, from the first frame: one full-height bar,
    // the cube on its left rail showing 64.
    for (const page of [p1, p2]) {
      await page.waitForSelector('.cube', { timeout: 20000 });
      const cubes = await page.locator('.cube').count();
      if (cubes !== 1) throw new Error(`${name(page)}: expected one cube, saw ${cubes}`);
      const cubeText = await page.locator('.cube').textContent();
      if (cubeText.trim() !== '64') throw new Error(`${name(page)}: centred cube should show 64, saw "${cubeText}"`);
      await assertHalf(page, '.cube', 'left', name(page));
      if ((await page.locator('.bg-bar').count()) !== 1) throw new Error(`${name(page)}: the bar should be one column`);
      const board = await box(page, '.bg-board');
      const bar = await box(page, '.bg-bar');
      if (bar.height < board.height * 0.8) throw new Error(`${name(page)}: bar is not full height (${bar.height} vs board ${board.height})`);
    }
    log('Cube fixture shows 64 on the left; the bar runs full height');

    // Opening mover plays their turn.
    await Promise.race([
      p1.waitForSelector(SOURCE, { timeout: 20000 }),
      p2.waitForSelector(SOURCE, { timeout: 20000 }),
    ]);
    const first = (await p1.locator(SOURCE).count()) > 0 ? p1 : p2;
    const second = first === p1 ? p2 : p1;
    await playFullTurn(first, name(first));
    log(`${name(first)}: opening turn played`);

    // The second player has the real choice: ROLL right, DOUBLE left.
    await second.waitForSelector('button:has-text("ROLL")', { timeout: 15000 });
    await assertHalf(second, 'button:has-text("ROLL")', 'right', name(second));
    await assertHalf(second, 'button:has-text("DOUBLE")', 'left', name(second));
    await second.screenshot({ path: `${SHOTS}/01-pre-roll-choice.png` });
    await second.click('button:has-text("DOUBLE")');
    log(`${name(second)}: doubled`);

    // The responder: TAKE/DROP on the left, the cube prominent at 2.
    await first.waitForSelector('button:has-text("TAKE")', { timeout: 15000 });
    await assertHalf(first, 'button:has-text("TAKE")', 'left', name(first));
    await assertHalf(first, 'button:has-text("DROP")', 'left', name(first));
    for (const page of [first, second]) {
      if ((await page.locator('.cube.pending').count()) !== 1) throw new Error(`${name(page)}: pending cube not marked`);
      const t = (await page.locator('.cube').textContent()).trim();
      if (t !== '2') throw new Error(`${name(page)}: offered cube should show 2, saw "${t}"`);
    }
    await first.screenshot({ path: `${SHOTS}/02-double-offer-${name(first)}.png` });
    await second.screenshot({ path: `${SHOTS}/02-double-waiting-${name(second)}.png` });
    await first.click('button:has-text("TAKE")');
    log(`${name(first)}: took the double`);

    // The cube relocates: taker's end on the taker's screen, opponent's end
    // on the doubler's, at value 2.
    await first.waitForFunction(() => !document.querySelector('.cube.pending'), null, { timeout: 10000 });
    for (const [page, place] of [[first, 'bottom'], [second, 'top']]) {
      const board = await box(page, '.bg-board');
      const cube = await box(page, '.cube');
      const t = (await page.locator('.cube').textContent()).trim();
      if (t !== '2') throw new Error(`${name(page)}: turned cube should show 2, saw "${t}"`);
      const below = mid(cube).y > mid(board).y + board.height * 0.15;
      const above = mid(cube).y < mid(board).y - board.height * 0.15;
      if (place === 'bottom' ? !below : !above) throw new Error(`${name(page)}: cube should sit at the ${place} of its rail`);
    }
    await first.screenshot({ path: `${SHOTS}/03-cube-taken.png` });
    log('Cube relocated to its owner at 2');

    // The doubler cannot re-double, so their turn rolls itself: fresh dice
    // appear with no ROLL button ever offered.
    let rolled = false;
    for (let i = 0; i < 40; i++) {
      if (await second.locator('button:has-text("ROLL")').count()) throw new Error(`${name(second)}: ROLL offered on a turn that should auto-roll`);
      if ((await second.locator('.die:not(.used)').count()) >= 2) { rolled = true; break; }
      await sleep(250);
    }
    if (!rolled) throw new Error(`${name(second)}: auto-roll did not produce dice`);
    await second.screenshot({ path: `${SHOTS}/04-auto-rolled.png` });
    log(`${name(second)}: turn auto-rolled, no button`);

    // Loop turns until somebody lands on the bar (best effort).
    await playFullTurn(second, name(second));
    let active = first;
    let barShot = false;
    for (let i = 0; i < 24 && !barShot; i++) {
      if (await active.locator('text=GAME OVER').count()) break;
      await playFullTurn(active, name(active));
      for (const page of [p1, p2]) {
        if ((await page.locator('.bg-bar .checker').count()) > 0) {
          await page.screenshot({ path: `${SHOTS}/05-bar-checker.png` });
          log(`${name(page)}: checker on the full-height bar`);
          barShot = true;
          break;
        }
      }
      active = active === first ? second : first;
    }
    if (!barShot) log('WARNING: no hit in the played turns; bar screenshot skipped');

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('BOARD SMOKE OK');
  } catch (e) {
    await Promise.all(
      [desktop, phone].flatMap((c) => c.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${c === desktop ? 'd' : 'p'}${i}.png` }).catch(() => {})))
    );
    console.error('BOARD SMOKE FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
