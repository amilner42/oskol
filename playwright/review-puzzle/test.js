/**
 * Screenshots of the puzzle page for eyeballing: the question (a checker
 * play and a cube question), a move staged, and the reveal for a guest, at
 * 390x844, 320x568 and 844x390, plus a desktop.
 *
 * The room and its puzzles are arranged by `test-puzzle/setup.exs` (a
 * finished game graded against a stubbed engine) unless PUZZLE_JSON carries
 * a previous run's result.
 *
 *   node playwright/review-puzzle/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-puzzle';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

function arrange() {
  if (process.env.PUZZLE_JSON) return JSON.parse(process.env.PUZZLE_JSON);
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(resultLine(out));
}

/** Stage a whole turn: one tap on a source point plays it with the next
 * die, exactly as at the table, until PLAY appears. */
async function stageATurn(page) {
  for (let i = 0; i < 6; i++) {
    if (await page.locator('#bg-action-play').count()) return;
    const source = page.locator('.bg-point.source, .bg-bar.source');
    if (!(await source.count())) return;
    await source.first().click();
    await page.waitForTimeout(150);
  }
}


(async () => {
  const setup = arrange();
  const movePuzzle = setup.players[0].puzzle.id;
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  try {
    for (const size of SIZES) {
      const context = await browser.newContext({ viewport: { width: size.width, height: size.height }, deviceScaleFactor: 1 });
      await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      const page = await context.newPage();

      await page.goto(`${BASE}/puzzles/${movePuzzle}`);
      await page.waitForSelector('#pz-board .bg-stack');
      await page.waitForTimeout(300);
      await page.screenshot({ path: `${OUT}/question-${size.name}.png` });

      await stageATurn(page);
      await page.screenshot({ path: `${OUT}/staged-${size.name}.png` });

      if (await page.locator('#bg-action-play').count()) {
        await page.click('#bg-action-play');
        await page.waitForSelector('#pz-reveal');
        await page.waitForTimeout(300);
        await page.screenshot({ path: `${OUT}/reveal-${size.name}.png`, fullPage: size.name !== 'landscape' });
        const second = page.locator('#pz-candidates .rp-cand:not([data-yours="true"])').first();
        if (await second.count()) {
          await second.click();
          await page.waitForTimeout(200);
          await page.screenshot({ path: `${OUT}/candidate-${size.name}.png` });
        }
      }

      await page.goto(`${BASE}/puzzles/${setup.cube}`);
      await page.waitForSelector('#pz-bands');
      await page.waitForTimeout(300);
      await page.screenshot({ path: `${OUT}/cube-${size.name}.png` });
      await page.click('#pz-band-1');
      await page.waitForSelector('#pz-scale');
      await page.waitForTimeout(300);
      await page.screenshot({ path: `${OUT}/cube-reveal-${size.name}.png`, fullPage: size.name !== 'landscape' });

      await context.close();
      log(`${size.name}: done`);
    }
  } finally {
    await browser.close();
  }
  log(`screenshots in ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
