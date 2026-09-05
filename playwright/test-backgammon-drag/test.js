/**
 * Drag-and-drop smoke for the bespoke backgammon board.
 *
 * 1. Alice (desktop, 1280x900, mouse) and Bob (phone, 390x844, touch) start
 *    a single game.
 * 2. Whoever moves first: an ILLEGAL drag (into the centre band) shows the
 *    ghost and the highlighted targets mid-drag but changes nothing on
 *    release; a LEGAL drag onto a highlighted point stages exactly one move
 *    (one die used, no double-fire from the synthetic click); tap-to-move
 *    still stages the next move after dragging.
 * 3. The turn is played; the other player rolls and drags too, so both the
 *    mouse and the touch path are exercised whichever seat won the opening.
 *
 * Mouse drags are real mouse.down/move/up; touch drags are real CDP
 * Input.dispatchTouchEvent sequences (Chromium turns them into the pointer
 * events the board listens to).
 *
 * Run with the server up:  node playwright/test-backgammon-drag/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || 'http://localhost:4000';
const SHOTS = process.env.SHOTS_DIR || 'playwright/screenshots/test-backgammon-drag';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const DRAGGABLE = '[data-drag-capture]';
const TARGET = '.bg-point.target, .bg-tray.target';

async function center(locator) {
  const box = await locator.boundingBox();
  if (!box) throw new Error('no bounding box for drag participant');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** A real pointer drag, mouse or touch, from the first draggable checker.
 * `pickDrop` runs mid-drag (ghost up, targets highlighted) and returns the
 * drop position; `midShot` is captured right before release. */
async function drag(page, { touch, pickDrop, midShot }) {
  const from = await center(page.locator(DRAGGABLE).first());
  const cdp = touch ? await page.context().newCDPSession(page) : null;
  const start = async () =>
    touch
      ? cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [from] })
      : (await page.mouse.move(from.x, from.y), page.mouse.down());
  const moveTo = async (x, y) =>
    touch
      ? cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y }] })
      : page.mouse.move(x, y, { steps: 4 });
  const end = async () =>
    touch ? cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }) : page.mouse.up();

  await start();
  await moveTo(from.x + 14, from.y + 14); // past the 8px threshold
  await page.waitForSelector('.bg-drag-ghost', { timeout: 5000 });
  if ((await page.locator(TARGET).count()) === 0) throw new Error('no highlighted targets mid-drag');
  const drop = await pickDrop(page);
  await moveTo(drop.x, drop.y);
  await sleep(150);
  if (midShot) await page.screenshot({ path: midShot });
  await end();
  await page.waitForFunction(() => !document.querySelector('.bg-drag-ghost'), null, { timeout: 5000 });
  if (cdp) await cdp.detach();
}

const usedDice = (page) => page.locator('.die.used').count();

/** The centre band of the board: never a drop zone. */
async function offTargetSpot(page) {
  const board = await page.locator('.bg-board').boundingBox();
  return { x: board.x + board.width / 2, y: board.y + board.height / 2 };
}

async function firstTargetSpot(page) {
  return center(page.locator(TARGET).first());
}

/** Play a whole turn: illegal drag (no-op), legal drag (one die), then taps
 * (still working after the drag) until the turn can be played. */
async function playTurnWithDrags(page, { touch, label }) {
  // The opening mover already has dice; later turns start with ROLL.
  const roll = page.locator('button:has-text("ROLL")');
  try {
    await page.waitForSelector(`${DRAGGABLE}, button:has-text("ROLL")`, { timeout: 15000 });
  } catch (_) {}
  if (await roll.count()) {
    await roll.click();
    await sleep(800);
  }
  await page.waitForSelector(DRAGGABLE, { timeout: 15000 });

  // Illegal drag: ghost and targets mid-flight, nothing on release.
  const before = await usedDice(page);
  await drag(page, { touch, pickDrop: offTargetSpot });
  await sleep(600);
  if ((await usedDice(page)) !== before) throw new Error(`${label}: an off-target drop staged a move`);
  if (await page.locator('.bg-point.selected').count()) throw new Error(`${label}: an off-target drop left a selection`);
  log(`${label}: illegal drag was a no-op`);

  // Legal drag: exactly one move staged (a click double-fire would stage two).
  await drag(page, {
    touch,
    pickDrop: firstTargetSpot,
    midShot: `${SHOTS}/${label}-mid-drag.png`,
  });
  await page.waitForFunction((n) => document.querySelectorAll('.die.used').length === n + 1, before, { timeout: 5000 });
  await page.screenshot({ path: `${SHOTS}/${label}-after-drop.png` });
  log(`${label}: legal drag staged one move`);

  // Tap-to-move still works after dragging; finish the turn on taps.
  let tapped = false;
  for (let i = 0; i < 4; i++) {
    const src = page.locator('.bg-point.source');
    if ((await src.count()) === 0) break;
    const used = await usedDice(page);
    await src.first().click();
    const target = page.locator('.bg-point.target, [title="Borne off"]:has(.ghost)');
    try { await target.first().waitFor({ timeout: 3000 }); } catch (_) { break; }
    await target.first().click();
    await page.waitForFunction((n) => document.querySelectorAll('.die.used').length > n, used, { timeout: 5000 });
    tapped = true;
  }
  if (tapped) log(`${label}: tap-to-move still works after dragging`);

  const play = page.locator('button:has-text("PLAY")');
  await play.waitFor({ timeout: 10000 });
  await play.click();
  log(`${label}: turn played`);
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
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).searchParams.get('game');
    log(`Game ${gameId} created`);

    const p2 = await phone.newPage();
    watch(p2, 'phone');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('[data-phx-main].phx-connected');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    log('Both players on the game page');

    await Promise.race([
      p1.waitForSelector(DRAGGABLE, { timeout: 20000 }),
      p2.waitForSelector(DRAGGABLE, { timeout: 20000 }),
    ]);
    const moverIsDesktop = (await p1.locator(DRAGGABLE).count()) > 0;
    const [first, second] = moverIsDesktop ? [p1, p2] : [p2, p1];
    const opts = (page) =>
      page === p1 ? { touch: false, label: 'desktop' } : { touch: true, label: 'phone' };

    await playTurnWithDrags(first, opts(first));
    await playTurnWithDrags(second, opts(second));

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('DRAG SMOKE OK');
  } catch (e) {
    await Promise.all(
      [desktop, phone].flatMap((c) => c.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${c === desktop ? 'd' : 'p'}${i}.png` }).catch(() => {})))
    );
    console.error('DRAG SMOKE FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
