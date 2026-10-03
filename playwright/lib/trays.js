/**
 * The bear-off trays, for the scripts that look at the live table on more
 * than one screen (test-backgammon-landscape, review-landscape-focus).
 *
 * Everywhere but a phone held upright the trays are one column at the end of
 * the home boards, three bins of five a side, as a real board keeps them;
 * upright they stay strips of three holders in the identity bars. These are
 * the checks for both, and a bear-off played on every screen they change
 * across, holding every box on the table still while checkers come off.
 */
const { execFileSync } = require('child_process');
const { BASE, resultLine } = require('./flows');

const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

async function box(page, selector) {
  const b = await page.locator(selector).first().boundingBox();
  if (!b) throw new Error(`no box for ${selector}`);
  return b;
}

const overlaps = (a, b) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

const within = (a, b) =>
  a.x >= b.x - 1 && a.y >= b.y - 1 && a.x + a.width <= b.x + b.width + 1 && a.y + a.height <= b.y + b.height + 1;

/**
 * The bear-off trays everywhere but a phone held upright: one column at the
 * end of the home boards, as a real board keeps them. Vertical, on the
 * board, beyond the felt on the home boards' side (the points beside it are
 * the two ace points, 1 and 24), as tall as the felt, the other side's tray
 * on top and the viewer's below, and the viewer's half a tap target. The
 * strips the identity bars used to carry are gone.
 */
async function assertTrayColumn(page, label) {
  const col = await box(page, '.bg-tray-col');
  const board = await box(page, '.bg-board');
  const grid = await box(page, '.bg-grid');
  const halves = await page.locator('.bg-half').all();
  const felt = await halves[halves.length - 1].boundingBox();
  must(col.height > 4 * col.width, `${label}: the tray is a column (${Math.round(col.width)}x${Math.round(col.height)})`);
  must(within(col, board), `${label}: the tray column is on the board`);
  must(col.x >= felt.x + felt.width - 1, `${label}: the tray column stands beyond the felt, at the home boards' end`);
  must(
    Math.abs(col.y - grid.y) <= 2 && Math.abs(col.height - grid.height) <= 2,
    `${label}: the tray column runs the felt's height (${Math.round(col.height)} of ${Math.round(grid.height)})`
  );

  // The points nearest it, top and bottom, are the two home boards' ends.
  const nearest = (row) =>
    page.evaluate((row) => {
      const points = [...document.querySelectorAll(`.bg-point.${row}`)];
      const last = points.reduce((a, b) => (b.getBoundingClientRect().x > a.getBoundingClientRect().x ? b : a));
      return last.getAttribute('title');
    }, row);
  const ends = [await nearest('top'), await nearest('bottom')];
  must(
    ends.includes('Point 1') && ends.includes('Point 24'),
    `${label}: the points beside the tray are the ace points (${ends.join(', ')})`
  );

  const top = await box(page, '.bg-off.top');
  const bottom = await box(page, '.bg-off.bottom');
  must(top.y + top.height <= bottom.y, `${label}: one tray above the other`);
  must((await page.locator('.bg-off.bottom.mine').count()) === 1, `${label}: the bottom tray is the viewer's`);
  must((await page.locator('.bg-off.top.theirs').count()) === 1, `${label}: the top tray is the other side's`);

  const covered = [];
  for (const point of await page.locator('.bg-point').all()) {
    const b = await point.boundingBox();
    if (b && overlaps(col, b)) covered.push(await point.getAttribute('title'));
  }
  must(covered.length === 0, `${label}: the tray column covers no point${covered.length ? ` (${covered.join(', ')})` : ''}`);

  must(
    !(await page.locator('.player-bar .bg-tray').first().isVisible()),
    `${label}: the identity bars carry no tray strip`
  );
  const taps = await page.evaluate(() => getComputedStyle(document.querySelector('.bg-off.mine')).pointerEvents);
  must(taps !== 'none', `${label}: the viewer's tray answers a tap (${taps})`);
}

/** A phone held upright keeps the strips in the identity bars, exactly as before. */
async function assertTrayStrips(page, label) {
  must(!(await page.locator('.bg-tray-col').isVisible()), `${label}: no tray column`);
  for (const side of ['.player-bar:not(.is-me)', '.player-bar.is-me']) {
    const bar = await box(page, side);
    const tray = await box(page, `${side} .bg-tray`);
    must(tray.width > 2 * tray.height, `${label}: the tray in ${side} is a strip (${Math.round(tray.width)}x${Math.round(tray.height)})`);
    must(within(tray, bar), `${label}: the tray sits inside ${side}`);
  }
}

/** A room where a seat may bear off, with checkers already off on both sides. */
function arrangeBearOffRoom() {
  if (process.env.BEAROFF_JSON) return JSON.parse(process.env.BEAROFF_JSON);
  log('arranging a bear-off room (mix run playwright/test-backgammon-landscape/bearoff.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-landscape/bearoff.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

/** The screens the trays are checked on: a column on all but the upright phone. */
const TRAY_SCREENS = [
  { name: 'phone-844x390', width: 844, height: 390, modes: ['expanded', 'compressed'] },
  { name: 'phone-667x375', width: 667, height: 375, modes: ['expanded', 'compressed'] },
  { name: 'phone-932x430', width: 932, height: 430, modes: ['expanded', 'compressed'] },
  { name: 'squat-640x480', width: 640, height: 480, modes: ['expanded', 'compressed'] },
  { name: 'desktop-1440x900', width: 1440, height: 900, desktop: true, modes: ['desktop'] },
  { name: 'portrait-390x844', width: 390, height: 844, upright: true, modes: ['upright'] },
];

/** Everything whose box a checker coming off may not move. */
const HELD = [
  '.bg-board',
  '.bg-grid',
  '.bg-half',
  '.bg-bar',
  '.bg-tray-col',
  '.bg-off.top',
  '.bg-off.bottom',
  '.off-plate.top',
  '.off-plate.bottom',
  '.player-bar:not(.is-me)',
  '.player-bar.is-me',
  '.player-bar.is-me .bg-tray',
  '.player-bar:not(.is-me) .bg-tray',
];

async function heldBoxes(page) {
  const out = {};
  for (const selector of HELD) {
    const all = await page.locator(selector).all();
    for (const [i, el] of all.entries()) {
      if (!(await el.isVisible())) continue;
      const b = await el.boundingBox();
      if (b) out[`${selector}#${i}`] = b;
    }
  }
  return out;
}

const sameBoxes = (a, b) =>
  Object.keys(a).length === Object.keys(b).length &&
  Object.keys(a).every(
    (k) =>
      b[k] &&
      Math.abs(a[k].x - b[k].x) < 0.5 &&
      Math.abs(a[k].y - b[k].y) < 0.5 &&
      Math.abs(a[k].width - b[k].width) < 0.5 &&
      Math.abs(a[k].height - b[k].height) < 0.5
  );

/**
 * A checker borne off by a tap on the viewer's tray, at every size the trays
 * change shape across: the column on a sideways phone (both layouts), a
 * squarish screen and a desktop, the strip upright. Every box on the table
 * is the same after it as before, and the tray counts what came off (the tap
 * bears off as far as the dice go). UNDO puts them back for the next screen.
 */
async function bearOffEverywhere(browser, { watch = () => {}, shot = null } = {}) {
  const room = arrangeBearOffRoom();
  const mover = room.players.find((p) => p.id === room.mover);
  const url = `${BASE}/backgammon/${room.game_id}`;

  for (const screen of TRAY_SCREENS) {
    const c = await browser.newContext({
      viewport: { width: screen.width, height: screen.height },
      hasTouch: !screen.desktop,
      isMobile: !screen.desktop,
      deviceScaleFactor: 1,
    });
    await c.addCookies([{ name: '_oskol_guest', value: mover.guest, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
    await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await c.newPage();
    watch(page, `bear-off ${screen.name}`);
    await page.goto(url);
    await page.waitForSelector('.bg-board', { timeout: 20000 });
    await page.waitForSelector('#bg-action-bear_off, .bg-off.mine.can-tap, .player-bar.is-me .bg-tray.cursor-pointer', {
      state: 'attached',
      timeout: 20000,
    });
    await sleep(1200); // the dice settle

    for (const mode of screen.modes) {
      const label = `bear-off @ ${screen.name}${screen.upright || screen.desktop ? '' : `, ${mode}`}`;
      const expanded = await page.evaluate(() => document.querySelector('.bg-page').classList.contains('is-expanded'));
      if ((mode === 'expanded' && !expanded) || (mode === 'compressed' && expanded)) {
        await page.click('#bg-focus-toggle');
        await sleep(500);
      }
      if (screen.upright) await assertTrayStrips(page, label);
      else await assertTrayColumn(page, label);

      const tray = screen.upright ? page.locator('.player-bar.is-me .bg-tray') : page.locator('.bg-off.mine');
      const countOf = async () =>
        screen.upright
          ? Number((await page.locator('.player-bar.is-me .off-count').textContent().catch(() => '0')) || 0)
          : Number(await tray.getAttribute('data-count'));
      const before = await countOf();
      const boxesBefore = await heldBoxes(page);

      await tray.click();
      await page.waitForFunction(
        ([upright, n]) => {
          const read = upright
            ? Number(document.querySelector('.player-bar.is-me .off-count')?.textContent || 0)
            : Number(document.querySelector('.bg-off.mine').getAttribute('data-count'));
          return read > n;
        },
        [!!screen.upright, before],
        { timeout: 10000 }
      );
      await sleep(400);
      const after = await countOf();
      must(after > before, `${label}: a tap on the tray bears checkers off (${before} -> ${after})`);
      const boxesAfter = await heldBoxes(page);
      const moved = Object.keys(boxesBefore).filter((k) => !sameBoxes({ [k]: boxesBefore[k] }, { [k]: boxesAfter[k] }));
      must(
        Object.keys(boxesBefore).length >= 8 && moved.length === 0,
        `${label}: nothing moved as it came off (${Object.keys(boxesBefore).length} boxes held${moved.length ? `; moved: ${moved.join(', ')}` : ''})`
      );
      if (shot) await page.screenshot({ path: shot(screen, mode) });

      // ...and back, for the next screen: UNDO takes one step at a time.
      for (let i = 0; i < 4 && (await countOf()) > before; i++) {
        const now = await countOf();
        await page.click('#bg-action-undo');
        await page.waitForFunction(
          ([upright, n]) => {
            const read = upright
              ? Number(document.querySelector('.player-bar.is-me .off-count')?.textContent || 0)
              : Number(document.querySelector('.bg-off.mine').getAttribute('data-count'));
            return read < n;
          },
          [!!screen.upright, now],
          { timeout: 10000 }
        );
        await sleep(300);
      }
      must((await countOf()) === before, `${label}: UNDO puts them back (${await countOf()})`);
    }
    await c.close();
    await sleep(800); // let the room notice the socket is gone
  }
}


module.exports = { assertTrayColumn, assertTrayStrips, arrangeBearOffRoom, bearOffEverywhere, TRAY_SCREENS };
