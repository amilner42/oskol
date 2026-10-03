/**
 * `Ui.Rolls` shot whole for a review: the six-by-six temperature map and the
 * best-to-worst bars, with the MAP / BARS toggle and the NUMBERS and MOVES
 * switches, at 390x844, 320x568 and 844x390.
 *
 *   01-map            the map as a page first gives it: no numbers, no moves,
 *                     the thrown roll (6-5) ringed in ink
 *   02-map-numbers    NUMBERS on: the value in every cell
 *   03-map-moves      NUMBERS and MOVES on: the engine's play in the spoken
 *                     line (a 50px cell cannot hold a notation)
 *   04-map-tapped     a tap on the worst roll: two lines under the grid, the
 *                     thrown roll first
 *   05-bars           BARS: 21 bars best to worst, each as wide as its roll
 *                     is likely, zero the line, the thrown roll marked
 *   06-bars-numbers   BARS with both switches on
 *   07-scale          all seven bands in one grid, with the numbers on, so
 *                     the scale and the contrast of the dice and the values
 *                     on every band can be read off one picture
 *   08-scale-sand     the same, on the SAND board instead of MIDNIGHT
 *
 * into playwright/screenshots/review-rolls-<tag>-<state>.png.
 *
 * WHY THIS ONE SERVES ITSELF. The component is pure and has no page yet (the
 * replay's ROLLS tab is `rolls-replay`, the analysis board's SHOW ROLLS is
 * `rolls-board`), so there is nothing on the real site to point a browser at.
 * This compiles `Harness.elm` -- which puts the real `Ui.Rolls.view` in the
 * real `.rp-panel` classes -- and serves it with the real built stylesheet
 * and the real self-hosted fonts out of priv/static. No Phoenix, no
 * database, no engine. When the ROLLS tab lands, these screens move into
 * `review-analysis` and this directory goes away.
 *
 * TWO BOARD THEMES, NOT A LIGHT AND A DARK SHELL. There is no dark shell in
 * this product (no `prefers-color-scheme`, no theme-swap class: app.css is
 * one light palette). What varies is the board, and the panel this drawing
 * lives in sits outside every `.bg-theme-*` scope -- so 08 is the proof of
 * that rather than a second palette: the page wears SAND instead of
 * MIDNIGHT and the drawing must not change by a pixel.
 *
 *   playwright/review-rolls/run.sh          (needs `mix assets.build` first;
 *                                            run.sh does it)
 */
const playwright = require('playwright');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const HERE = __dirname;
const STATIC = path.join(ROOT, 'priv/static');
const SHOTS = path.join(ROOT, 'playwright/screenshots');
const PORT = Number(process.env.ROLLS_HARNESS_PORT || 4489);
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SIZES = [
  ['390', { width: 390, height: 844 }],
  ['320', { width: 320, height: 568 }],
  ['844x390', { width: 844, height: 390 }],
];

/** The fixture, out of the test module that asserts its numbers, so the
 *  picture and the test cannot disagree. */
function fixture() {
  const src = fs.readFileSync(path.join(ROOT, 'assets/tests/RollsTest.elm'), 'utf8');
  const m = src.match(/fixtureJson\s*=\s*"""([\s\S]*?)"""/);
  if (!m) throw new Error('could not find fixtureJson in assets/tests/RollsTest.elm');
  const json = m[1].trim();
  JSON.parse(json); // fail here rather than in the browser
  return json;
}

function buildElm() {
  log('compiling Harness.elm against assets/src');
  execFileSync(path.join(ROOT, 'node_modules/.bin/elm'),
    ['make', 'Harness.elm', '--output=harness.js'],
    { cwd: HERE, stdio: 'inherit' });
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

/** The harness's own files, then everything else out of priv/static, so
 *  /assets/css/app.css and /fonts/*.woff2 are the ones the site serves. */
function serve(openingJson) {
  const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/fixture.js') {
      res.writeHead(200, { 'content-type': TYPES['.js'] });
      res.end(`window.OPENING_JSON = ${JSON.stringify(openingJson)};\n`);
      return;
    }
    const local = url === '/' ? 'index.html' : url.replace(/^\/+/, '');
    for (const base of [HERE, STATIC]) {
      const file = path.resolve(base, local);
      if (!file.startsWith(base)) break;
      if (fs.existsSync(file) && fs.statSync(file).isFile()) {
        res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' });
        res.end(fs.readFileSync(file));
        return;
      }
    }
    res.writeHead(404).end('not here');
  });
  return new Promise((done) => server.listen(PORT, () => done(server)));
}

const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));

async function shot(page, tag, name) {
  await settle(page);
  await page.waitForTimeout(120);
  await page.screenshot({ path: `${SHOTS}/review-rolls-${tag}-${name}.png`, fullPage: true });
}

async function noSideScroll(page, where) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (wide > 0) throw new Error(`${where}: the page scrolls ${wide}px sideways`);
}

/** The panel's box, so a toggle that moves something is caught rather than
 *  looked for in two pictures. */
const box = (page, selector) => page.$eval(selector, (el) => {
  const r = el.getBoundingClientRect();
  return { w: Math.round(r.width), h: Math.round(r.height), top: Math.round(r.top) };
});

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  if (!fs.existsSync(path.join(STATIC, 'assets/css/app.css'))) {
    throw new Error('priv/static/assets/css/app.css is not built -- run `mix assets.build` (or run.sh)');
  }
  const openingJson = fixture();
  buildElm();
  const server = await serve(openingJson);
  log(`serving the harness on http://localhost:${PORT}`);

  const browser = await playwright.chromium.launch({
    headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'],
  });
  const errors = [];
  try {
    for (const [tag, size] of SIZES) {
      const ctx = await browser.newContext({ viewport: size, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      const page = await ctx.newPage();
      page.on('pageerror', (e) => errors.push(`${tag} pageerror: ${e.message}`));
      page.on('console', (m) => {
        if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${tag} console: ${m.text()}`);
      });

      log(`${tag}: the map`);
      await page.goto(`http://localhost:${PORT}/`, { waitUntil: 'load' });
      await page.waitForSelector('#rolls .rl-cell');

      const cells = await page.$$eval('#rolls .rl-cell', (els) => els.length);
      if (cells !== 36) throw new Error(`${tag}: ${cells} cells, not 36`);
      await noSideScroll(page, `${tag} map`);
      const before = await box(page, '#rp-panel');
      await shot(page, tag, '01-map');

      log(`${tag}: NUMBERS`);
      await page.click('[data-switch="numbers"]');
      await shot(page, tag, '02-map-numbers');
      const after = await box(page, '#rp-panel');
      if (before.w !== after.w || before.h !== after.h || before.top !== after.top) {
        throw new Error(`${tag}: the panel moved when NUMBERS was pressed: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
      }

      log(`${tag}: MOVES`);
      await page.click('[data-switch="moves"]');
      await shot(page, tag, '03-map-moves');

      log(`${tag}: a tap`);
      await page.click('#rolls .rl-cell[data-dice="4-1"]');
      await page.waitForSelector('#rolls .rl-said.is-picked');
      await shot(page, tag, '04-map-tapped');

      log(`${tag}: the bars`);
      await page.click('[data-switch="numbers"]'); // back off, as a page first gives it
      await page.click('[data-switch="moves"]');
      await page.click('[data-tab="bars"]');
      await page.waitForSelector('#rolls [data-rolls="bars"]');
      const rects = await page.$$eval('#rolls [data-rolls="bars"] rect', (els) => els.length);
      if (rects !== 21) throw new Error(`${tag}: ${rects} bars, not 21`);
      // the double's bar must be half the non-double's, gap included
      const widths = await page.$$eval('#rolls [data-rolls="bars"] rect', (els) =>
        Object.fromEntries(els.map((e) => [e.getAttribute('data-dice'), Number(e.getAttribute('width'))])));
      const ratio = (widths['6-5'] + 1.2) / (widths['6-6'] + 1.2);
      if (Math.abs(ratio - 2) > 0.001) throw new Error(`${tag}: a non-double's bar is ${ratio}x a double's, not 2x`);
      await noSideScroll(page, `${tag} bars`);
      await shot(page, tag, '05-bars');

      await page.click('[data-switch="numbers"]');
      await page.click('[data-switch="moves"]');
      await shot(page, tag, '06-bars-numbers');

      log(`${tag}: the whole scale`);
      await page.click('[data-tab="map"]');
      await page.click('#screen-scale');
      await page.waitForFunction(() =>
        [...document.querySelectorAll('#rolls .rl-cell')].some((e) => e.classList.contains('is-lit')));
      await shot(page, tag, '07-scale');

      log(`${tag}: the same, on SAND`);
      const scaleBefore = await box(page, '#rolls .rl-map');
      await page.click('#theme-sand');
      await page.waitForSelector('.bg-theme-sand');
      const scaleAfter = await box(page, '#rolls .rl-map');
      if (JSON.stringify(scaleBefore) !== JSON.stringify(scaleAfter)) {
        throw new Error(`${tag}: the map changed shape when the board theme did`);
      }
      await shot(page, tag, '08-scale-sand');

      await ctx.close();
    }
  } finally {
    await browser.close();
    server.close();
  }

  if (errors.length) {
    console.error(errors.join('\n'));
    throw new Error(`${errors.length} page error(s)`);
  }
  log(`done -- ${SHOTS}/review-rolls-*.png`);
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
