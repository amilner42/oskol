/**
 * Screenshots of a puzzle reveal's verdict in each of the shapes it takes
 * now that 0.02 given up is a miss: RIGHT on the best play, RIGHT within
 * 0.02 ("Not a mistake"), and a miss named by its band -- ?! DUBIOUS,
 * ? BAD, ?? VERY BAD -- with and without "so it comes back".
 *
 * The page is the real one on a real puzzle (`test-puzzle/setup.exs`
 * arranges a graded game); the attempt's answer is the server's own, with
 * its verdict, band and cost rewritten on the way back so every shape can
 * be shown on one position. Phone, small, sideways and desktop.
 *
 *   playwright/review-verdict/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-verdict';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

const SCHEDULE = { level_before: 3, level_after: 0, due: Date.now() + 86400000, amendable: true, self_grade: false, patched: false };

const SHAPES = [
  { name: 'best', verdict: 'pass', band: 'best', cost: 0.0 },
  { name: 'ok', verdict: 'pass', band: 'ok', cost: 0.012 },
  { name: 'dubious', verdict: 'fail', band: 'doubtful', cost: 0.04 },
  { name: 'dubious-scheduled', verdict: 'fail', band: 'doubtful', cost: 0.04, schedule: SCHEDULE },
  { name: 'bad', verdict: 'fail', band: 'bad', cost: 0.11 },
  { name: 'very-bad', verdict: 'fail', band: 'very_bad', cost: 0.37 },
];

const WORDS = {
  best: ['RIGHT', 'That is the play.'],
  ok: ['RIGHT', 'Within 0.02 of the best. Not a mistake.'],
  dubious: ['?! DUBIOUS', 'Gives up 0.04 — a mistake.'],
  'dubious-scheduled': ['?! DUBIOUS', 'Gives up 0.04 — a mistake, so it comes back.'],
  bad: ['? BAD', 'Gives up 0.11 — a mistake.'],
  'very-bad': ['?? VERY BAD', 'Gives up 0.37 — a mistake.'],
};

function must(ok, what) {
  if (!ok) throw new Error(`FAILED: ${what}`);
  log(`ok: ${what}`);
}

function arrange() {
  if (process.env.PUZZLE_JSON) return JSON.parse(process.env.PUZZLE_JSON);
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(resultLine(out));
}

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
  const puzzle = setup.players[0].puzzle.id;
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  try {
    for (const size of SIZES) {
      for (const shape of SHAPES) {
        const context = await browser.newContext({ viewport: { width: size.width, height: size.height }, deviceScaleFactor: 1 });
        await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
        await context.route(/\/papi\/puzzles\/[^/]+\/attempts$/, async (route) => {
          const response = await route.fetch();
          const body = await response.json();
          body.verdict = shape.verdict;
          body.band = shape.band;
          body.cost = shape.cost;
          if (shape.schedule) body.schedule = shape.schedule;
          await route.fulfill({ response, json: body });
        });
        const page = await context.newPage();
        await page.goto(`${BASE}/puzzles/${puzzle}`);
        await page.waitForSelector('#pz-board .bg-stack');
        await stageATurn(page);
        await page.click('#bg-action-play');
        await page.waitForSelector('#pz-verdict');
        await page.waitForTimeout(300);
        const [word, sentence] = WORDS[shape.name];
        must((await page.textContent('#pz-verdict .pz-verdict-word')).trim() === word, `${size.name} ${shape.name}: "${word}"`);
        must((await page.textContent('#pz-verdict .pz-verdict-why')).trim() === sentence, `${size.name} ${shape.name}: "${sentence}"`);
        await page.locator('#pz-reveal').scrollIntoViewIfNeeded();
        await page.screenshot({ path: `${OUT}/${shape.name}-${size.name}.png`, fullPage: size.name !== 'landscape' });
        await context.close();
      }
      log(`${size.name}: done`);
    }
  } finally {
    await browser.close();
  }
  log(`screenshots in ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
