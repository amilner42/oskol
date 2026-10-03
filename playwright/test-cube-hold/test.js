/**
 * The cube buttons are held, not tapped: DOUBLE on the live table against
 * Sage.
 *
 * The room is arranged by `setup.exs` (a match to 5 against Sage, at the
 * start of the person's turn with DOUBLE on offer) and handed here as JSON
 * in CUBE_HOLD_JSON, or arranged here. Nothing answers Sage's engine in a
 * smoke, so Sage never answers the double; the point is the offer.
 *
 *   mix run -e 'Code.eval_file("playwright/test-cube-hold/setup.exs")'
 *   CUBE_HOLD_JSON='<the last line it printed>' node playwright/test-cube-hold/test.js
 *
 * 1. DOUBLE / ROLL, one word each, at 390x844, 320x568, 844x390 (focus and
 *    compressed) and 1440x900, on the board and on one line
 * 2. A quick tap (finger and mouse) and a quick Enter do nothing: no cube
 *    on offer, DOUBLE still there; the tap says HOLD over the word, quietly
 * 3. Mid-hold the bar fills inside the button and nothing moves, frame by
 *    frame; letting go early does nothing
 * 4. A full hold with a finger offers the double, once: the cube on Sage's
 *    side at 2, WAITING FOR THE TAKE...
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, hold, resultLine, seatedContext } = require('../lib/flows');
const { execFileSync } = require('child_process');

const SHOTS = process.env.CUBE_HOLD_SHOTS || 'playwright/screenshots/test-cube-hold';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrangeRoom() {
  if (process.env.CUBE_HOLD_JSON) return JSON.parse(process.env.CUBE_HOLD_JSON);
  log('arranging a room against Sage (mix run playwright/test-cube-hold/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-cube-hold/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

const box = (page, sel) => page.evaluate((s) => {
  const el = document.querySelector(s);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height].map((n) => Math.round(n * 10) / 10).join(',');
}, sel);

/** What the band shows: the two buttons' boxes, their words, the cube. */
async function band(page) {
  return {
    double: await box(page, '#bg-action-double'),
    roll: await box(page, '#bg-action-roll'),
    pending: await page.locator('.cube.pending').count(),
  };
}

async function main() {
  const room = arrangeRoom();
  fs.mkdirSync(SHOTS, { recursive: true });
  const url = `${BASE}/backgammon/${room.game_id}`;

  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  const open = async (viewport, touch) => {
    const context = await seatedContext(browser, room.guest, { viewport, hasTouch: touch, isMobile: touch, deviceScaleFactor: 2 });
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    await page.goto(url);
    await page.waitForSelector('#bg-action-double', { timeout: 15000 });
    await sleep(500);
    return { context, page };
  };

  try {
    // 1. One word each, at every size, on one line and on the screen.
    for (const [tag, viewport, touch, compressed] of [
      ['390x844', { width: 390, height: 844 }, true, false],
      ['320x568', { width: 320, height: 568 }, true, false],
      ['844x390-focus', { width: 844, height: 390 }, true, false],
      ['844x390-compressed', { width: 844, height: 390 }, true, true],
      ['1440x900', { width: 1440, height: 900 }, false, false],
    ]) {
      const { context, page } = await open(viewport, touch);
      try {
        if (compressed) {
          await page.click('#bg-focus-toggle');
          await sleep(400);
        }
        must((await page.textContent('#bg-action-double')).trim() === 'DOUBLE', `${tag}: DOUBLE says one word`);
        must((await page.textContent('#bg-action-roll')).trim() === 'ROLL', `${tag}: ROLL says one word`);
        const fits = await page.evaluate(() => ['#bg-action-double', '#bg-action-roll'].every((s) => {
          const el = document.querySelector(s);
          const r = el.getBoundingClientRect();
          const line = parseFloat(getComputedStyle(el).lineHeight) || 16;
          return r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight && el.scrollWidth <= el.clientWidth + 1 && el.clientHeight < line * 2 + 30;
        }));
        must(fits, `${tag}: both on the screen, on one line`);
        await page.screenshot({ path: `${SHOTS}/01-${tag}.png` });
      } finally {
        await context.close();
      }
    }

    // 2-4 on a phone, upright.
    const { context, page } = await open({ width: 390, height: 844 }, true);
    try {
      const before = await band(page);
      must(before.pending === 0 && before.double, 'DOUBLE is on offer and no cube is');

      await hold(page, '#bg-action-double', { ms: 90, touch: true });
      await sleep(150);
      must(await page.isVisible('#bg-action-double .hold-nudge'), 'a quick tap says HOLD on the button');
      await page.screenshot({ path: `${SHOTS}/02-quick-tap-hold.png` });
      await sleep(900);
      let now = await band(page);
      must(now.pending === 0 && now.double === before.double, 'a quick finger tap does nothing, and nothing moved');

      await page.click('#bg-action-double');
      await sleep(900);
      now = await band(page);
      must(now.pending === 0 && now.double === before.double, 'a mouse click does nothing');

      await page.focus('#bg-action-double');
      await page.keyboard.press('Enter');
      await page.keyboard.press(' ');
      await sleep(900);
      now = await band(page);
      must(now.pending === 0 && now.double === before.double, 'a quick Enter or Space does nothing');

      // 3. A hold let go at 250ms: the bar part-way, nothing moving.
      const cdp = await context.newCDPSession(page);
      const [x, y, w, h] = before.double.split(',').map(Number);
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x + w / 2, y: y + h / 2 }] });
      const frames = [];
      for (let i = 0; i < 5; i += 1) {
        await sleep(40);
        frames.push(await box(page, '#bg-action-double'));
        frames.push(await box(page, '#bg-action-roll'));
      }
      const fill = await page.evaluate(() => {
        const m = getComputedStyle(document.querySelector('#bg-action-double .hold-fill')).transform;
        return m === 'none' ? 0 : Number(m.split('(')[1].split(',')[0]);
      });
      await page.screenshot({ path: `${SHOTS}/03-mid-hold.png` });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await cdp.detach();
      must(fill > 0.15 && fill < 0.95, `mid-hold the bar is part-way across (${fill.toFixed(2)})`);
      // the press itself sinks the button 4px (.btn-arcade:active); its size never changes
      must(frames.every((f) => f.split(',').slice(2).join() === before.double.split(',').slice(2).join() || f.split(',').slice(2).join() === before.roll.split(',').slice(2).join()), 'frame by frame the buttons keep their size');
      await sleep(900);
      now = await band(page);
      must(now.pending === 0 && now.double === before.double && now.roll === before.roll, 'let go early: nothing sent, nothing moved');

      // 4. The full hold.
      await hold(page, '#bg-action-double', { ms: 600, touch: true });
      await page.waitForSelector('.cube.pending', { timeout: 5000 });
      must((await page.textContent('.cube.pending')).trim() === '2', 'a full hold offers the double: the cube on offer at 2');
      await page.waitForSelector('text=WAITING FOR THE TAKE', { timeout: 5000 });
      must(!(await page.locator('#bg-action-double').count()), 'DOUBLE is gone: it went once');
      await page.screenshot({ path: `${SHOTS}/04-doubled.png` });
    } finally {
      await context.close();
    }

    must(errors.length === 0, `no page errors (${errors.join('; ')})`);
    log('PASS');
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
