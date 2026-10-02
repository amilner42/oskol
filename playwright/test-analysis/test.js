/**
 * The analysis board (`/analysis`), part 1: setting a position up.
 *
 * 1. ☰ has Analysis right after Puzzles, and it opens the board
 * 2. A desktop builds a position with the mouse: left click adds White,
 *    right click adds Black, a left click on Black paints over it, the x
 *    takes one off, the bar's halves take the same clicks; a sixteenth is
 *    refused and its tray flashes; ROLL, the cube, DOUBLE?, a match, its
 *    scores and Crawford; FLIP and FLIP back; IMPORT reads an id (and
 *    refuses one that is not); COPY puts the id on the clipboard
 * 3. A phone (390x844) builds one with taps and a long press, and picks a
 *    roll from the sheet
 * 4. At 320x568 and sideways (844x390) a tap on every point lands on that
 *    point, and nothing scrolls sideways
 * 5. The doors in: ?xgid= opens that position; ?p= of a puzzle that is not
 *    there opens the opening and says so
 *
 * Through all of it the board, the brushes, the strip, every control in
 * it, the line under it and ANALYZE keep their boxes to the pixel: nothing
 * moves when a control changes.
 *
 * Screenshots at 390x844, 320x568, 844x390 and 1440x900 go to
 * playwright/screenshots/analysis-*.png.
 *
 * Run with the server up:  node playwright/test-analysis/test.js
 * Or on its own port:      playwright/test-analysis/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE } = require('../lib/flows');

const SHOTS = 'playwright/screenshots';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const OPENING = 'XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10';

// The boxes that must never move, and every control in the strip.
const HELD = [
  '#an-board', '.bg-still', '.player-bar.is-me', '.player-bar:not(.is-me)',
  '#an-brushes', '#an-strip', '#an-check', '#an-analyze',
  '#an-brush-white', '#an-brush-black', '#an-brush-remove',
  '#an-turn', '#an-ask', '#an-dice', '#an-ask-double', '#an-ask-take', '#an-cube', '#an-cube-owner',
  '#an-length', '#an-game', '#an-score-white', '#an-score-black', '#an-crawford',
  '#an-opening', '#an-clear', '#an-flip', '#an-xgid', '#an-xgid-copy', '#an-xgid-import',
];

async function boxes(page) {
  return page.evaluate((sels) => {
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    return out;
  }, HELD);
}

function sameBoxes(tag, before, after) {
  for (const s of HELD) {
    if (JSON.stringify(before[s]) !== JSON.stringify(after[s]))
      throw new Error(`${tag}: ${s} moved from ${JSON.stringify(before[s])} to ${JSON.stringify(after[s])}`);
  }
}

// Elm draws on the next animation frame: a read straight after a click
// would see the page before it. Every click and tap here waits for two.
const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));

function settled(page) {
  const click = page.click.bind(page);
  const tap = page.tap.bind(page);
  page.click = async (...args) => { await click(...args); await settle(page); };
  page.tap = async (...args) => { await tap(...args); await settle(page); };
  return page;
}

const xgid = async (page) => { await settle(page); return page.inputValue('#an-xgid'); };

// A point's count as the id has it: White positive, Black negative. 0 is
// Black's bar (O's), 25 White's (X's), 1..24 the points.
function countAt(id, index) {
  const ch = id.slice(5).split(':')[0][index];
  if (ch === '-') return 0;
  if (ch >= 'A' && ch <= 'P') return ch.charCodeAt(0) - 64;
  return -(ch.charCodeAt(0) - 96);
}

const field = (id, n) => id.slice(5).split(':')[n];

async function expectCount(page, tag, index, want) {
  const got = countAt(await xgid(page), index);
  if (got !== want) throw new Error(`${tag}: index ${index} holds ${got}, not ${want} (${await xgid(page)})`);
}

// What the board draws on a point: its white and black checkers (a stack
// over five shows five and carries the count on its top one).
async function drawnOn(page, sel) {
  return page.$eval(sel, (el) => {
    const count = (color) => {
      const cs = [...el.querySelectorAll(`.checker.${color}`)];
      const label = el.querySelector(`.checker.${color} .checker-count`);
      return label ? Number(label.textContent) : cs.length;
    };
    return { white: count('white'), black: count('black') };
  });
}

async function expectLine(page, tag, want) {
  const got = (await page.innerText('#an-check')).trim();
  if (got !== want) throw new Error(`${tag}: the line says "${got}", not "${want}"`);
}

async function longPress(page, cdp, sel) {
  await page.locator(sel).scrollIntoViewIfNeeded();
  const b = await page.locator(sel).boundingBox();
  const x = b.x + b.width / 2;
  const y = b.y + b.height / 2;
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
  await page.waitForTimeout(700);
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await settle(page);
}

const watch = (page, who, errors) => {
  page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
  });
};

async function open(page, path = '/analysis') {
  await page.goto(`${BASE}${path}`);
  await page.waitForSelector('#an-pt-24');
}

// A box shows all it holds: the hint (the only place a phone learns about
// the long press) and the line under the strip at its longest.
async function fits(page, tag, sel) {
  await settle(page);
  const over = await page.$eval(sel, (el) => [el.scrollWidth - el.clientWidth, el.scrollHeight - el.clientHeight]);
  if (over[0] > 0 || over[1] > 0) throw new Error(`${tag}: ${sel} is cut off (${over[0]}px wide, ${over[1]}px tall)`);
}

// Whichever hint this screen shows (a mouse's or a finger's), whole.
async function hintFits(page, tag) {
  let seen = 0;
  for (const hint of ['.an-hint-touch', '.an-hint-mouse']) {
    const shown = await page.$eval(hint, (el) => getComputedStyle(el).display !== 'none');
    if (shown) { seen++; await fits(page, tag, hint); }
  }
  if (seen !== 1) throw new Error(`${tag}: ${seen} hints show`);
}

// The dead cube: White two away on a cube of 2 that White owns, so the
// line says its longest sentence.
const DEAD = 'XGID=-b----E-C---eE---c-e----B-:1:1:1:00:5:0:0:7:10';
const DEAD_LINE = 'No double is possible here: the cube already covers what White needs';

async function deadCube(page, tag, press) {
  await press('#an-xgid-import');
  await page.waitForSelector('#an-import');
  await page.fill('#an-import-text', DEAD);
  await press('#an-import-go');
  await page.waitForSelector('#an-import', { state: 'detached' });
  await press('#an-ask-double');
  await expectLine(page, tag, DEAD_LINE);
  await fits(page, tag, '#an-check');
}

async function noSideScroll(page, tag) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (wide > 0) throw new Error(`${tag}: the page scrolls ${wide}px sideways`);
}

async function menu(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, 'menu', errors);
    await page.goto(`${BASE}/puzzles`);
    await page.click('#nav-more');
    await page.waitForSelector('#nav-menu');
    const items = await page.$$eval('#nav-menu button', (bs) => bs.map((b) => b.id));
    const at = items.indexOf('nav-analysis');
    if (at < 0 || items[at - 1] !== 'nav-puzzles') throw new Error(`☰ lists ${JSON.stringify(items)}: Analysis is not right after Puzzles`);
    await page.click('#nav-analysis');
    await page.waitForURL(/\/analysis$/);
    await page.waitForSelector('#an-pt-1');
    if ((await xgid(page)) !== OPENING) throw new Error(`the menu's board opens on ${await xgid(page)}`);
    await expectLine(page, 'the menu', 'Pick a roll');
    if (!(await page.isDisabled('#an-analyze'))) throw new Error('ANALYZE is on with no roll picked');
    log('☰ Analysis opens the opening position, no roll picked');
  } finally {
    await context.close();
  }
}

async function desktop(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE });
  try {
    const page = settled(await context.newPage());
    watch(page, 'desktop', errors);
    await open(page);
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-01-opening.png` });
    const held = await boxes(page);
    const still = async (tag) => sameBoxes(`desktop ${tag}`, held, await boxes(page));

    await page.click('#an-clear');
    if (field(await xgid(page), 0) !== '-'.repeat(26)) throw new Error(`CLEAR left ${await xgid(page)}`);
    await expectLine(page, 'cleared', 'Put some White checkers on the board');
    await still('CLEAR');

    // Left adds White, right adds Black.
    for (let i = 0; i < 3; i++) await page.click('#an-pt-6');
    for (let i = 0; i < 2; i++) await page.click('#an-pt-19', { button: 'right' });
    await expectCount(page, 'left clicks', 6, 3);
    await expectCount(page, 'right clicks', 19, -2);
    const six = await drawnOn(page, '#an-pt-6');
    const nineteen = await drawnOn(page, '#an-pt-19');
    if (six.white !== 3 || nineteen.black !== 2) throw new Error(`the board draws ${JSON.stringify(six)} on 6 and ${JSON.stringify(nineteen)} on 19`);
    await still('clicks');

    // White over Black takes one of Black's off; the x takes one off anything.
    await page.click('#an-pt-19');
    await expectCount(page, 'painting over', 19, -1);
    await page.click('#an-brush-remove');
    await page.click('#an-pt-6');
    await page.click('#an-pt-19', { button: 'right' });
    await expectCount(page, 'the x', 6, 2);
    await expectCount(page, 'the x, right', 19, 0);
    await page.click('#an-brush-white');
    await still('the brushes');

    // The bar's halves.
    await page.click('#an-bar-white');
    await page.click('#an-bar-black', { button: 'right' });
    await expectCount(page, "White's bar", 25, 1);
    await expectCount(page, "Black's bar", 0, -1);
    await still('the bar');
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-02-built.png` });

    // A sixteenth is refused; White's tray flashes.
    await page.click('#an-opening');
    if ((await xgid(page)) !== OPENING) throw new Error(`OPENING gave ${await xgid(page)}`);
    await page.click('#an-pt-10');
    if ((await xgid(page)) !== OPENING) throw new Error(`a sixteenth White checker went on: ${await xgid(page)}`);
    if (!(await page.$('#analysis.an-flash-white-1'))) throw new Error("White's tray did not flash for the sixteenth");
    await page.click('#an-pt-10', { button: 'right' });
    if (!(await page.$('#analysis.an-flash-black-0'))) throw new Error("Black's tray did not flash for its sixteenth");
    await still('a sixteenth');

    // The roll.
    await page.click('#an-dice');
    await page.waitForSelector('#an-roll-sheet');
    await still('the sheet open');
    await page.click('#an-roll-31');
    await page.waitForSelector('#an-roll-sheet', { state: 'detached' });
    if (field(await xgid(page), 4) !== '31') throw new Error(`the roll reads ${field(await xgid(page), 4)}`);
    await expectLine(page, 'a roll', '');
    if (await page.isDisabled('#an-analyze')) throw new Error('ANALYZE is off on an askable position');
    await still('a roll');

    // The cube: off 1 it goes to whoever is to play; the owner turns it.
    await page.click('#an-cube');
    let id = await xgid(page);
    if (field(id, 1) !== '1' || field(id, 2) !== '1') throw new Error(`the cube at 2 reads ${id}`);
    if ((await page.innerText('#an-cube-owner')).trim() !== 'WHITE') throw new Error('the cube at 2 is not White\'s');
    await page.click('#an-cube-owner');
    if (field(await xgid(page), 2) !== '-1') throw new Error(`the owner turned reads ${await xgid(page)}`);
    await page.click('#an-ask-double');
    await expectLine(page, 'a double on Black\'s cube', "No double is possible here: the cube is Black's");
    if (!(await page.isDisabled('#an-analyze'))) throw new Error('ANALYZE is on with a refusal in the line');
    await page.click('#an-ask-take');
    await expectLine(page, 'a take of Black\'s redouble', '');
    if (field(await xgid(page), 4) !== 'D') throw new Error(`a take reads ${await xgid(page)}`);
    for (let i = 0; i < 6; i++) await page.click('#an-cube');
    if ((await page.innerText('#an-cube-owner')).trim() !== 'CENTER' || !(await page.isDisabled('#an-cube-owner')))
      throw new Error('a cube back at 1 is not in the middle');
    await page.click('#an-dice');
    await page.click('#an-roll-66');
    await still('the cube');

    // A match: its length, the scores, and Crawford only one away.
    await page.click('#an-game');
    if ((await page.innerText('#an-game')).trim() !== 'MATCH TO 7') throw new Error(`MATCH reads ${await page.innerText('#an-game')}`);
    if (!(await page.isDisabled('#an-crawford'))) throw new Error('CRAWFORD is on with nobody one away');
    for (let i = 0; i < 6; i++) await page.click('#an-score-white-plus');
    if (await page.isDisabled('#an-crawford')) throw new Error('CRAWFORD is off with White one away');
    await page.click('#an-crawford');
    id = await xgid(page);
    if (field(id, 5) !== '6' || field(id, 6) !== '0' || field(id, 7) !== '1' || field(id, 8) !== '7')
      throw new Error(`7-point match, 6-0, Crawford reads ${id}`);
    await page.click('#an-length-plus');
    if (field(await xgid(page), 7) !== '0') throw new Error('Crawford stayed on with nobody one away');
    for (let i = 0; i < 3; i++) await page.click('#an-score-black-plus');
    await page.click('#an-length-minus');
    await still('the match');
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-03-match.png` });

    // FLIP, and back.
    const before = await xgid(page);
    await page.click('#an-flip');
    const flipped = await xgid(page);
    if (flipped === before) throw new Error('FLIP changed nothing');
    if (field(flipped, 5) !== field(before, 6) || field(flipped, 6) !== field(before, 5)) throw new Error(`FLIP did not swap the scores: ${before} -> ${flipped}`);
    await page.click('#an-flip');
    if ((await xgid(page)) !== before) throw new Error(`FLIP twice gave ${await xgid(page)}, not ${before}`);
    await page.click('#an-game');
    await still('FLIP');

    // IMPORT.
    const pasted = 'XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10';
    await page.click('#an-xgid-import');
    await page.waitForSelector('#an-import');
    await page.fill('#an-import-text', 'not one');
    await page.click('#an-import-go');
    if ((await page.innerText('#an-import-error')).trim() !== 'That is not a position id') throw new Error('a bad id was not refused in the dialog');
    await page.fill('#an-import-text', pasted);
    await page.click('#an-import-go');
    await page.waitForSelector('#an-import', { state: 'detached' });
    if ((await xgid(page)) !== pasted) throw new Error(`IMPORT gave ${await xgid(page)}, not ${pasted}`);
    await still('IMPORT');

    // Who is to play, and the longest line.
    await page.click('#an-turn-black');
    if (!(await page.$('#an-turn-black.is-on'))) throw new Error('TO PLAY Black did not take');
    await still('TO PLAY');
    await deadCube(page, 'desktop dead cube', (sel) => page.click(sel));
    await still('the longest line');
    await hintFits(page, 'desktop');
    await fits(page, 'desktop: the whole id shows', '#an-xgid');
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-04-dead-cube.png` });

    // COPY.
    await page.click('#an-xgid-copy');
    if ((await page.innerText('#an-xgid-copy')).trim() !== 'COPIED') throw new Error('COPY did not say so');
    const copied = await page.evaluate(() => navigator.clipboard.readText());
    if (copied !== (await xgid(page))) throw new Error(`COPY put "${copied}" on the clipboard`);
    await still('COPY');
    log('desktop: clicks, right clicks, the x, the bar, the sixteenth, the strip, FLIP, IMPORT, COPY; nothing moved');
  } finally {
    await context.close();
  }
}

async function phone(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, 'phone', errors);
    const cdp = await context.newCDPSession(page);
    await open(page);
    await page.screenshot({ path: `${SHOTS}/analysis-390-01-opening.png`, fullPage: true });
    const held = await boxes(page);
    const still = async (tag) => sameBoxes(`phone ${tag}`, held, await boxes(page));

    await page.tap('#an-clear');
    await page.tap('#an-pt-1');
    await page.tap('#an-pt-1');
    await expectCount(page, 'taps', 1, 2);
    await longPress(page, cdp, '#an-pt-24');
    await longPress(page, cdp, '#an-pt-24');
    await expectCount(page, 'long presses', 24, -2);
    const drawn = await drawnOn(page, '#an-pt-24');
    if (drawn.black !== 2) throw new Error(`the board draws ${JSON.stringify(drawn)} on 24 after two long presses`);
    await page.tap('#an-pt-24');
    await expectCount(page, 'a tap over Black', 24, -1);
    await longPress(page, cdp, '#an-bar-black');
    await expectCount(page, "a long press on Black's bar", 0, -1);
    await still('taps and long presses');

    await page.tap('#an-opening');
    await page.tap('#an-dice');
    await page.waitForSelector('#an-roll-sheet');
    await page.screenshot({ path: `${SHOTS}/analysis-390-02-rolls.png` });
    await page.tap('#an-roll-64');
    await page.waitForSelector('#an-roll-sheet', { state: 'detached' });
    if (field(await xgid(page), 4) !== '64') throw new Error(`the sheet's 6-4 reads ${await xgid(page)}`);
    await page.tap('#an-game');
    await page.tap('#an-score-black-plus');
    await page.tap('#an-cube');
    await still('the strip');
    await page.screenshot({ path: `${SHOTS}/analysis-390-03-set.png`, fullPage: true });
    await page.tap('#an-flip');
    await still('FLIP');
    await page.tap('#an-turn-black');
    await still('TO PLAY');
    await deadCube(page, 'phone dead cube', (sel) => page.tap(sel));
    await still('the longest line');
    await hintFits(page, 'phone');
    await noSideScroll(page, 'phone');
    log('phone: taps, long presses, the bar, the sheet of rolls, FLIP; nothing moved');
  } finally {
    await context.close();
  }
}

// Every point answers where it is drawn, at a size and a turn of the phone.
async function aim(browser, errors, tag, viewport) {
  const context = await browser.newContext({ viewport, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, tag, errors);
    await open(page);
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}.png`, fullPage: true });
    const held = await boxes(page);
    // Fifteen a colour: one half of the board at a time.
    for (const half of [[1, 12], [13, 24]]) {
      await page.tap('#an-clear');
      for (let p = half[0]; p <= half[1]; p++) {
        // the board from the top of the page, as a phone opens it
        await page.evaluate(() => window.scrollTo(0, 0));
        const b = await page.locator(`#an-pt-${p}`).boundingBox();
        // Tap the point's own spot on the screen, not its element: the tap
        // must land on that point and no other.
        await page.touchscreen.tap(b.x + b.width / 2, b.y + b.height * (p > 12 ? 0.25 : 0.75));
        await settle(page);
      }
      const id = await xgid(page);
      for (let p = 1; p <= 24; p++) {
        const want = p >= half[0] && p <= half[1] ? 1 : 0;
        if (countAt(id, p) !== want) throw new Error(`${tag}: taps on points ${half[0]}..${half[1]} gave ${id}`);
      }
    }
    await page.tap('#an-bar-white');
    await expectCount(page, `${tag} bar`, 25, 1);
    sameBoxes(tag, held, await boxes(page));
    await deadCube(page, `${tag} dead cube`, (sel) => page.tap(sel));
    sameBoxes(`${tag} the longest line`, held, await boxes(page));
    await hintFits(page, tag);
    await noSideScroll(page, tag);
    log(`${tag}: a tap on each of the 24 points lands on that point`);
  } finally {
    await context.close();
  }
}

async function doors(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, 'doors', errors);
    const id = 'XGID=-b----E-C---eE---c-e----B-:0:0:-1:52:0:0:1:0:10';
    await open(page, `/analysis?xgid=${encodeURIComponent(id)}`);
    if ((await xgid(page)) !== id) throw new Error(`?xgid= opened ${await xgid(page)}`);
    if (!(await page.$('#an-turn-black.is-on'))) throw new Error('?xgid= with Black on roll is not Black to play');
    await open(page, '/analysis?p=nope0000');
    await page.waitForFunction(() => document.querySelector('#an-check')?.textContent.trim() === 'That puzzle is gone.');
    if ((await xgid(page)) !== OPENING) throw new Error(`a gone puzzle opened ${await xgid(page)}`);
    log('doors: ?xgid= opens the position as it is; a gone ?p= opens the opening and says so');
  } finally {
    await context.close();
  }
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  try {
    await menu(browser, errors);
    await desktop(browser, errors);
    await phone(browser, errors);
    await aim(browser, errors, '320', { width: 320, height: 568 });
    await aim(browser, errors, '844x390', { width: 844, height: 390 });
    await doors(browser, errors);
    if (errors.length) throw new Error(`console errors:\n${errors.join('\n')}`);
    log('ALL PASSED');
  } catch (e) {
    console.error(e);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
