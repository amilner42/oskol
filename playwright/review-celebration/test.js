/**
 * Screenshots and a recording of the celebration: the card a practice run
 * puts under the reveal the moment today's set is done -- the ring filling
 * and its check, "Today's 5 done.", what moved, the grid's squares
 * stepping up, what patching won back, then KEEP GOING beside I'M DONE.
 *
 * Every shot is a run played to today's target from a fresh shape
 * (review-practice's shape.exs, SHAPE_STATE=today_three: the very bad
 * moves have two answered today and the day's three new ones to come), at
 * 390x844, 320x568, 844x390 and 1440x900:
 *
 *   01-card-<size>        the card settled (data-settled="true")
 *   02-reduced-<size>     the same moment with reduced motion: drawn at once
 *   03-keep-going-phone   KEEP GOING: the run goes on, the ring at 5/8
 *   04-set-<size>         a run through the openings: "N of 15 learned."
 *   05-all-missed-phone   a run of misses: "Every one of these is back on its way"
 *   frames/phone-NN-Tms   the phone's card as it plays, T ms in (about 75 ms apart)
 *   video/phone-run.webm  the phone's run, recorded
 *
 * What is measured, and must be equal before the card and once it has
 * settled, at every size: the board, the strip, the verdict, the level
 * line and the band under the board -- each one's place in the page (its
 * own scroll containers taken out, so the card being scrolled into view
 * is not a move) and its size. Nothing scrolls sideways.
 *
 *   playwright/review-celebration/run.sh   (serves its own port and database)
 *   ONLY=phone ...                          one size, for a quick look
 */
const playwright = require('playwright');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { stageATurn } = require('../lib/puzzles');

const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-celebration';
fs.rmSync(`${OUT}/video`, { recursive: true, force: true });
fs.rmSync(`${OUT}/frames`, { recursive: true, force: true });
fs.mkdirSync(`${OUT}/frames`, { recursive: true });
fs.mkdirSync(`${OUT}/video`, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];
const PHONE = SIZES[0];
const DESKTOP = SIZES[3];

function mix(script, env = {}) {
  const out = execFileSync('mix', ['run', '-e', `Code.eval_file("${script}")`], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, ...env },
  });
  return JSON.parse(resultLine(out));
}

function must(condition, message) {
  if (!condition) throw new Error(`failed: ${message}`);
  log(`ok: ${message}`);
}

/** Where things sit in the page: each element's box with every scroll
 * between it and the page taken out, so a scroll is not a move. */
const layout = (page) =>
  page.evaluate(() => {
    const at = (s) => {
      const el = document.querySelector(s);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      let y = r.top + window.scrollY;
      let x = r.left + window.scrollX;
      for (let p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
        y += p.scrollTop;
        x += p.scrollLeft;
      }
      return { x: Math.round(x), y: Math.round(y), w: Math.round(r.width), h: Math.round(r.height) };
    };
    return {
      board: at('#pz-board'),
      strip: at('#pz-progress'),
      verdict: at('#pz-verdict'),
      level: at('#pz-level'),
      band: at('#pz-actions'),
    };
  });

/** A screenshot; a whole-page one from the top, so the bar is where it
 * belongs rather than wherever the page was scrolled to. */
async function shot(page, options) {
  if (options.fullPage) {
    await page.evaluate(() => window.scrollTo(0, 0));
    await sleep(120);
  }
  await page.screenshot(options);
}

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

/** The engine's best play on the shaped position (every shaped mistake is
 * the same question): 8/2 6/2, a tap on each point in turn. */
async function playBest(page) {
  await page.waitForSelector('#pz-board .bg-point.source');
  await page.click('#pz-board [title="Point 8"]');
  await sleep(200);
  await page.click('#pz-board [title="Point 6"]');
  await page.waitForSelector('#bg-action-play');
  await page.click('#bg-action-play');
}

async function playAny(page) {
  await page.waitForSelector('#pz-bands, #bg-action-play, .bg-point.source, [data-move-source]', { timeout: 15000 });
  if (await page.locator('#pz-bands').count()) {
    await page.locator('#pz-bands .pz-band').first().click();
  } else {
    await stageATurn(page);
    await page.click('#bg-action-play');
  }
}

async function another(page) {
  const was = new URL(page.url()).pathname;
  await page.click('#pz-next');
  await page.waitForFunction((from) => new URL(location.href).pathname !== from, was, { timeout: 15000 });
  await page.waitForSelector('#pz-reveal', { state: 'detached' });
}

/** A run of `plays` from the card in front of the hub (or a set's row),
 * every answer but the last followed by ANOTHER. Resolves at the last
 * reveal, with where everything sat the moment it landed. */
async function runTo(page, plays, { row = null } = {}) {
  await page.goto(`${BASE}/puzzles`);
  if (row) {
    await page.waitForSelector(`#hub-row-${row}`);
    await page.click(`#hub-row-${row}`);
    await page.waitForSelector(`#hub-card[data-deck="${row}"]`);
  }
  await page.waitForSelector('#hub-go');
  await page.click('#hub-go');
  await page.waitForURL(/\/puzzles\/[^/]+$/);
  for (let n = 0; n < plays.length; n++) {
    await page.waitForSelector('#pz-board .bg-stack');
    await sleep(200);
    await plays[n](page);
    await page.waitForSelector('#pz-reveal');
    if (n < plays.length - 1) {
      must(!(await page.locator('#pz-today-done').count()), `answer ${n + 1}: today's set is not done yet, no card`);
      await another(page);
    }
  }
  return layout(page);
}

/** The card, played and settled. */
async function settled(page) {
  await page.waitForSelector('#pz-today-done[data-settled="true"]', { timeout: 15000 });
  await sleep(150);
}

/** The card as it plays: wait for it to start, then pictures of its box
 * as fast as the browser will take them, each named by how far into the
 * motion it was taken. The box is read once: an element screenshot would
 * wait for the card to stop moving, which is the thing being photographed. */
async function frames(page, name, count) {
  // The first screenshot of a page is slow: take it while the card waits
  // for the scroll, so the ones that matter come at the browser's pace.
  await page.waitForSelector('#pz-today-done.is-ready', { timeout: 15000 });
  await page.screenshot({ path: `${OUT}/frames/${name}-warm.png` });
  fs.rmSync(`${OUT}/frames/${name}-warm.png`);
  await page.waitForSelector('#pz-today-done[data-playing="true"]', { timeout: 15000 });
  const start = Date.now();
  const clip = await page.evaluate(() => {
    const b = document.querySelector('#pz-today-done').getBoundingClientRect();
    return { x: Math.max(0, b.x - 6), y: Math.max(0, b.y - 14), width: b.width + 12, height: b.height + 22 };
  });
  for (let i = 0; i < count; i++) {
    // The card's own clock where the browser has one: how far into its
    // motion this frame is (its last keyframe runs from the start).
    const played = await page.evaluate(() => {
      const a = document.getAnimations().find((x) => x.animationName === 'pz-cele-settle');
      return a && a.currentTime !== null ? Math.round(a.currentTime) : null;
    });
    const ms = played === null ? Date.now() - start : played;
    await page.screenshot({ path: `${OUT}/frames/${name}-${String(i).padStart(2, '0')}-${String(ms).padStart(4, '0')}ms.png`, clip });
    await sleep(50);
  }
}

const ringOf = (page) => page.evaluate(() => { const r = document.querySelector('#pz-ring'); return `${r.dataset.done}/${r.dataset.target}`; });

(async () => {
  const setup = process.env.CELE_SETUP_FILE
    ? JSON.parse(fs.readFileSync(process.env.CELE_SETUP_FILE, 'utf8'))
    : mix('playwright/review-practice/setup.exs');
  log(`arranged: ${JSON.stringify(setup)}`);
  const shape = (state) => log(`shaped: ${JSON.stringify(mix('playwright/review-practice/shape.exs', { SHAPE_EMAIL: setup.email, SHAPE_STATE: state }))}`);

  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  const open = async (size, extra = {}) => {
    const context = await seatedContext(browser, setup.guest, { deviceScaleFactor: 2, viewport: { width: size.width, height: size.height }, ...extra });
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(e.message));
    return { context, page };
  };
  const ONLY = process.env.ONLY;

  try {
    // ---- the card, at every size, measured ----
    for (const size of SIZES.filter((s) => !ONLY || s.name === ONLY).filter(() => !process.env.SKIP_CARD)) {
      shape('today_three');
      const recording = size === PHONE;
      const { context, page } = await open(size, recording ? { recordVideo: { dir: `${OUT}/video`, size: { width: 390, height: 844 } } } : {});
      const before = await runTo(page, [playBest, playAny, playBest]);
      must(await page.locator('#pz-today-done').count(), `${size.name}: the third answer finishes today's set, and the card is under the reveal`);
      must(!(await page.locator('#pz-next').count()), `${size.name}: the band under the board keeps SHARE; the way on is the card's`);
      if (recording) await frames(page, 'phone', 24);
      await settled(page);
      const after = await layout(page);
      for (const key of Object.keys(before)) {
        must(JSON.stringify(before[key]) === JSON.stringify(after[key]),
          `${size.name}: ${key} is where it was before the card (${JSON.stringify(after[key])})`);
      }
      must(await ringOf(page) === '5/5', `${size.name}: the strip's ring is full`);
      must((await page.textContent('#pz-today-title')).trim() === "Today's 5 done.", `${size.name}: "Today's 5 done."`);
      const steps = (await page.textContent('#pz-today-steps')).trim();
      must(steps === '2 stepped up a level', `${size.name}: what moved: "${steps}"`);
      must(await page.locator('#pz-today-grid .grid-step').count() === 2, `${size.name}: the two that stepped up step up on the grid`);
      must(/^Patched so far: \d+\.\d PR won back\.$/.test((await page.textContent('#pz-today-tail')).trim()), `${size.name}: what patching has won back`);
      must(await page.isVisible('#pz-keep-going') && await page.isVisible('#pz-done'), `${size.name}: KEEP GOING beside I'M DONE`);
      await noSideways(page, size.name);
      await page.mouse.move(0, 0);
      await shot(page, { path: `${OUT}/01-card-${size.name}.png`, fullPage: size.name === 'phone' || size.name === 'small' });

      if (size === PHONE) {
        // KEEP GOING: three more, the ring 5/8, and ANOTHER works again.
        await page.click('#pz-keep-going');
        await page.waitForSelector('#pz-reveal', { state: 'detached' });
        await page.waitForSelector('#pz-board .bg-stack');
        const grown = await ringOf(page);
        must(grown === '5/8', `KEEP GOING goes on, the ring reads ${grown}`);
        await playBest(page);
        await page.waitForSelector('#pz-reveal');
        must(!(await page.locator('#pz-today-done').count()), 'and the card is not drawn twice in a run');
        must(await page.isVisible('#pz-next'), 'ANOTHER is back under the board');
        await sleep(400);
        await shot(page, { path: `${OUT}/03-keep-going-phone.png`, fullPage: true });
        await another(page);
        log('ANOTHER after KEEP GOING went on to the next');
      }
      await context.close();
    }

    if (!ONLY) {
      // ---- reduced motion: the same moment, drawn at once ----
      for (const size of [PHONE, DESKTOP]) {
        shape('today_three');
        const { context, page } = await open(size, { reducedMotion: 'reduce' });
        await runTo(page, [playBest, playAny, playBest]);
        await page.waitForSelector('#pz-today-done[data-settled="true"]', { timeout: 5000 }).catch(async (e) => { console.log(await page.evaluate(() => { const c = document.querySelector('#pz-today-done'); const r = document.querySelector('#pz-today-ring').getBoundingClientRect(); return JSON.stringify([c.className, c.dataset.playing, r.top, r.bottom, innerHeight, scrollY, document.documentElement.scrollHeight]); })); throw e; });
        const moving = await page.evaluate(() => document.getAnimations()
          .filter((a) => a instanceof CSSAnimation && a.effect && a.effect.target && a.effect.target.closest && a.effect.target.closest('#pz-today-done')).map((a) => a.animationName || a.transitionProperty || 'other'));
        must(moving.length === 0, `${size.name}, reduced motion: nothing in the card animates (${moving})`);
        await sleep(200);
        await shot(page, { path: `${OUT}/02-reduced-${size.name}.png`, fullPage: size === PHONE });
        await context.close();
      }

      // ---- a run of misses ----
      {
        shape('today_three');
        const { context, page } = await open(PHONE);
        await runTo(page, [playAny, playAny, playAny]);
        await settled(page);
        const steps = (await page.textContent('#pz-today-steps')).trim();
        must(steps === 'Every one of these is back on its way', `a run of misses: "${steps}"`);
        await shot(page, { path: `${OUT}/05-all-missed-phone.png`, fullPage: true });
        await context.close();
      }

      // ---- a set ----
      for (const size of [PHONE, DESKTOP]) {
        shape('today_three');
        const { context, page } = await open(size);
        await runTo(page, [playAny, playAny, playAny], { row: 'openings' });
        await settled(page);
        must((await page.textContent('#pz-today-eyebrow')).trim() === 'OPENINGS', 'the set is named over the card');
        const tail = (await page.textContent('#pz-today-tail')).trim();
        must(/^\d+ of 15 learned\.$/.test(tail), `a set says how much of it is learned: "${tail}"`);
        await page.mouse.move(0, 0);
        await shot(page, { path: `${OUT}/04-set-${size.name}.png`, fullPage: size === PHONE });
        await context.close();
      }
    }

    if (errors.length) throw new Error(errors.join('; '));
    const videos = fs.readdirSync(`${OUT}/video`).filter((f) => f.endsWith('.webm'));
    videos.forEach((f, i) => fs.renameSync(path.join(`${OUT}/video`, f), path.join(`${OUT}/video`, i === 0 ? 'phone-run.webm' : `phone-run-${i}.webm`)));
    log(`screenshots in ${OUT}`);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
