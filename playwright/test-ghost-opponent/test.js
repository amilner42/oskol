/**
 * The opponent watches the mover think: staged checkers show on the other
 * board as ghosts, live, before PLAY.
 *
 * Two players, two browser contexts (a seat is the browser's guest cookie):
 * the mover at 1440x900, the watcher on a phone at 390x844.
 *
 * 1. The mover stages two moves of two different checkers; within a second
 *    the watcher sees two ghosts, and the places they left ringed, over a
 *    committed board that has not moved. Nothing on the watcher's board
 *    shifts when they come, and a ghost takes no tap.
 * 2. The mover undoes one: the watcher sees one.
 * 3. The watcher reloads mid-turn: the ghost is still there (it comes from
 *    the projection of the log, not from anything the page remembered).
 * 4. The mover finishes and plays: the watcher sees the played position, the
 *    mover's own, with no ghosts.
 *
 * Screenshots of both sides, and of the watcher at 1440x900, go to
 * playwright/screenshots/test-ghost-opponent.
 *
 * Run with the server up:  node playwright/test-ghost-opponent/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { createGame, joinByLink } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/test-ghost-opponent';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SOURCE = '.bg-point.source';

/** Every point's committed checkers, as "N:wwb" strings: ghosts left out. */
async function points(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('.bg-point')]
      .map((p) => {
        const men = [...p.querySelectorAll('.checker:not(.ghost)')]
          .map((c) => (c.classList.contains('white') ? 'w' : 'b') + (c.textContent || '').trim())
          .join('');
        return `${p.getAttribute('title').replace('Point ', '')}:${men}`;
      })
      .sort()
      .join(' '),
  );
}

/** Where every point and the bar sit on the screen, to catch a shift. */
async function layout(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll('.bg-point, .bg-bar, .bg-band')]
      .map((el) => {
        const r = el.getBoundingClientRect();
        return `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)},${Math.round(r.height)}`;
      })
      .join(' '),
  );
}

const ghosts = (page) => page.locator('.checker.ghost').count();

/** Wait until the watcher's board shows `n` ghosts; how long it took. */
async function seeGhosts(page, n, timeout = 1000) {
  const t0 = Date.now();
  try {
    await page.waitForFunction((k) => document.querySelectorAll('.checker.ghost').length === k, n, { timeout });
  } catch (_) {
    throw new Error(`the watcher should see ${n} ghost(s) within ${timeout} ms, sees ${await ghosts(page)}`);
  }
  return Date.now() - t0;
}

/** The point a tap just landed a checker on: the one that gained one. */
function gained(before, after) {
  const count = (s) => Object.fromEntries(s.split(' ').map((x) => [x.split(':')[0], x.split(':')[1].replace(/\d/g, '').length]));
  const b = count(before);
  const a = count(after);
  return Object.keys(a).find((k) => a[k] > (b[k] || 0));
}

/** Tap a legal origin (not `avoid`), and wait for a die to be spent. */
async function stage(page, avoid) {
  const used = await page.locator('.die.used').count();
  const sources = page.locator(SOURCE);
  const n = await sources.count();
  let picked = null;
  for (let i = 0; i < n; i += 1) {
    const title = await sources.nth(i).getAttribute('title');
    if (title !== `Point ${avoid}`) {
      picked = sources.nth(i);
      break;
    }
  }
  if (!picked) picked = sources.first();
  await picked.click();
  await page.waitForFunction((k) => document.querySelectorAll('.die.used').length > k, used, { timeout: 5000 });
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const wide = { viewport: { width: 1440, height: 900 } };
  const phone = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
  const ctxA = await browser.newContext(wide);
  const ctxB = await browser.newContext(phone);
  for (const c of [ctxA, ctxB]) await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const pa = await ctxA.newPage();
    watch(pa, 'A');
    const game = await createGame(pa, { name: 'Alice' });
    const pb = await ctxB.newPage();
    watch(pb, 'B');
    await joinByLink(pb, game.inviteUrl, 'Bob');
    await pa.waitForURL(`**/backgammon/${game.gameId}**`);
    log(`game ${game.gameId}: both seated`);

    // Whoever won the opening roll moves first. The mover is "A" from here.
    await Promise.race([pa.waitForSelector(SOURCE, { timeout: 20000 }), pb.waitForSelector(SOURCE, { timeout: 20000 })]);
    await sleep(300);
    const aMoves = (await pa.locator(SOURCE).count()) > 0;
    const mover = aMoves ? pa : pb;
    const watcher = aMoves ? pb : pa;
    // The watcher is the phone, whichever seat that is: give the mover the
    // wide window and the watcher the phone.
    await mover.setViewportSize({ width: 1440, height: 900 });
    await watcher.setViewportSize({ width: 390, height: 844 });
    await watcher.waitForSelector('.bg-board .checker', { timeout: 20000 });
    // Let the opening dice land on both screens.
    await sleep(1500);
    const start = await points(watcher);
    const frame = await layout(watcher);
    if ((await ghosts(watcher)) !== 0) throw new Error('nothing is staged yet, but the watcher sees a ghost');

    // 1. Two moves of two different checkers.
    const before = await points(mover);
    await stage(mover, null);
    const landed = gained(before, await points(mover));
    await stage(mover, landed);
    const took = await seeGhosts(watcher, 2);
    log(`two moves staged: the watcher saw two ghosts in ${took} ms`);
    await sleep(300); // the ghosts' arrival settles
    if ((await points(watcher)) !== start) throw new Error("the watcher's committed board moved while the mover staged");
    if ((await layout(watcher)) !== frame) throw new Error("the watcher's board shifted when the ghosts came");
    const rings = await watcher.locator('.checker.leaving').count();
    if (rings !== 2) throw new Error(`the two places left should be ringed, saw ${rings}`);
    const tappable = await watcher.$$eval('.checker.ghost', (gs) => gs.map((g) => getComputedStyle(g).pointerEvents));
    if (!tappable.every((p) => p === 'none')) throw new Error(`a ghost must take no tap, saw pointer-events ${tappable}`);
    if ((await watcher.locator(SOURCE).count()) !== 0) throw new Error('the watcher has nothing to move');
    if ((await mover.locator('.checker.ghost').count()) !== 0) throw new Error('the mover sees ghosts of their own moves');
    await watcher.screenshot({ path: `${SHOTS}/01-watcher-two-ghosts-390.png` });
    await mover.screenshot({ path: `${SHOTS}/02-mover-staged-1440.png` });
    await watcher.setViewportSize({ width: 1440, height: 900 });
    await sleep(400);
    await watcher.screenshot({ path: `${SHOTS}/03-watcher-two-ghosts-1440.png` });
    await watcher.setViewportSize({ width: 390, height: 844 });
    await sleep(400);

    // 2. UNDO takes one back.
    await mover.click('#bg-action-undo');
    log(`undo: the watcher saw one ghost in ${await seeGhosts(watcher, 1)} ms`);
    if ((await watcher.locator('.checker.leaving').count()) !== 1) throw new Error('one place left should be ringed after the undo');

    // 3. A reload mid-turn: the ghost is still there.
    await watcher.reload();
    await watcher.waitForSelector('.bg-board .checker', { timeout: 20000 });
    await seeGhosts(watcher, 1, 5000);
    if ((await points(watcher)) !== start) throw new Error('after a reload the watcher should see the committed board');
    await sleep(300);
    await watcher.screenshot({ path: `${SHOTS}/04-watcher-reloaded-390.png` });
    log('reloaded mid-turn: the ghost is still there');

    // 4. The mover finishes the turn and plays.
    for (let i = 0; i < 4; i += 1) {
      if ((await mover.locator(SOURCE).count()) === 0) break;
      await stage(mover, null);
    }
    await mover.waitForSelector('#bg-action-play', { timeout: 5000 });
    const played = await points(mover);
    await mover.click('#bg-action-play');
    await seeGhosts(watcher, 0, 2000);
    await watcher.waitForFunction(
      (want) =>
        [...document.querySelectorAll('.bg-point')]
          .map((p) => {
            const men = [...p.querySelectorAll('.checker:not(.ghost)')]
              .map((c) => (c.classList.contains('white') ? 'w' : 'b') + (c.textContent || '').trim())
              .join('');
            return `${p.getAttribute('title').replace('Point ', '')}:${men}`;
          })
          .sort()
          .join(' ') === want,
      played,
      { timeout: 2000 },
    );
    if ((await watcher.locator('.checker.leaving').count()) !== 0) throw new Error('no place is left once the turn is played');
    await sleep(300);
    await watcher.screenshot({ path: `${SHOTS}/05-watcher-played-390.png` });
    log("played: the watcher sees the mover's position, no ghosts");

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('GHOST OPPONENT OK');
  } catch (e) {
    for (const [i, pg] of [...ctxA.pages(), ...ctxB.pages()].entries()) {
      await pg.screenshot({ path: `${SHOTS}/99-failure-${i}.png` }).catch(() => {});
    }
    console.error('GHOST OPPONENT FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
