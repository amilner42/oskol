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
 * Part 2, ANALYZE, against a stand-in engine (setup.exs, in a VM of its
 * own, on ANALYSIS_STUB_PORT: the server's ANALYSIS_URL must name it, as
 * run.sh and bin/check arrange):
 *
 * 6. A desktop asks about a position nobody has asked before: ANALYZE
 *    becomes the plate counting seconds, in ANALYZE's own box; the answer
 *    lands in the panel ("4-ply · asked just now"); a candidate goes on the
 *    board and the dice take it back; asked again it is "already analyzed";
 *    a change to the position clears the panel
 * 7. The opening 3-1: 8/5 6/5 ranked first; SHARE copies /puzzles/<id>
 *    ("Link copied"); OPEN AS PUZZLE is that link; a stranger opening it
 *    gets a puzzle page whose head asks the question and names nobody, and
 *    plays it to the reveal
 * 8. DOUBLE? is answered with the cube's three equities; a roll that plays
 *    nothing says so, with no TRY AGAIN
 * 9. At 390x844, 320x568, 844x390 and 1440x900 the panel fills and clears
 *    and nothing moves, the panel's own box included
 *
 * Screenshots at 390x844, 320x568, 844x390 and 1440x900 go to
 * playwright/screenshots/analysis-*.png.
 *
 * Run with the server up:  node playwright/test-analysis/test.js
 * Or on its own port:      playwright/test-analysis/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { spawn } = require('child_process');
const { BASE, resultLine } = require('../lib/flows');

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


// ---------- Part 2: ANALYZE ----------

const STUB_PORT = Number(process.env.ANALYSIS_STUB_PORT || Number(new URL(BASE).port || 80) + 10000);
const OPENING_31 = 'XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10';
const OPENING_DOUBLE = OPENING;
// White on the bar against a closed board: 6-4 plays nothing.
const DANCE = 'XGID=-c----N------------bbbbbbA:0:0:1:64:0:0:1:0:10';

/** The stand-in engine, listening, and a way to stop it. */
async function startEngine() {
  log(`starting the stand-in engine on ${STUB_PORT} (setup.exs)`);
  const child = spawn('mix', ['run', '--no-start', '-e', 'Code.eval_file("playwright/test-analysis/setup.exs")'], {
    env: { ...process.env, ANALYSIS_STUB_PORT: String(STUB_PORT), MIX_ENV: process.env.MIX_ENV || 'dev' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const stop = () => { try { child.stdin.end(); } catch (_) {} try { child.kill(); } catch (_) {} };
  process.on('exit', stop);
  await new Promise((resolve, reject) => {
    let out = '';
    child.stdout.on('data', (d) => {
      out += d;
      try { resultLine(out); resolve(); } catch (_) {}
    });
    child.on('exit', (code) => reject(new Error(`the stand-in engine stopped (${code}):\n${out.slice(-2000)}`)));
  });
  return stop;
}

// A position nobody has asked about: the opening in a 25-point match at a
// score and a roll picked here, so the engine is asked and the page waits.
function freshPosition() {
  const r = (n) => Math.floor(Math.random() * n);
  const a = 1 + r(6);
  const b = 1 + r(6);
  return `XGID=-b----E-C---eE---c-e----B-:0:0:1:${Math.max(a, b)}${Math.min(a, b)}:${r(23)}:${r(23)}:0:25:10`;
}

// The boxes that hold through an ask: part 1's, ANALYZE's slot and the
// panel's.
const ASKED = [...HELD.filter((s) => s !== '#an-analyze'), '.an-analyze', '#an-panel'];

async function askedBoxes(page) {
  return page.evaluate((sels) => {
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    out.pageHeight = document.documentElement.scrollHeight;
    return out;
  }, ASKED);
}

function sameAsked(tag, before, after) {
  for (const s of [...ASKED, 'pageHeight']) {
    if (JSON.stringify(before[s]) !== JSON.stringify(after[s]))
      throw new Error(`${tag}: ${s} moved from ${JSON.stringify(before[s])} to ${JSON.stringify(after[s])}`);
  }
}

const text = async (page, sel) => (await page.innerText(sel)).trim();

async function analyze(page, press) {
  await press('#an-analyze');
  await page.waitForSelector('#an-answer, #an-refused', { timeout: 30000 });
  await settle(page);
}

async function verdict(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE });
  try {
    const page = settled(await context.newPage());
    watch(page, 'verdict', errors);

    // 6. A position nobody has asked about.
    await open(page, `/analysis?xgid=${encodeURIComponent(freshPosition())}`);
    const held = await askedBoxes(page);
    const still = async (tag) => sameAsked(`verdict ${tag}`, held, await askedBoxes(page));
    await page.click('#an-analyze');
    await page.waitForSelector('#an-asking');
    if (!/^ASKING THE ENGINE… \d+ s$/.test(await text(page, '#an-asking'))) throw new Error(`the plate says "${await text(page, '#an-asking')}"`);
    await still('the plate');
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-05-asking.png` });
    await page.waitForSelector('#an-answer', { timeout: 30000 });
    await settle(page);
    if ((await text(page, '#an-depth')) !== '4-ply · asked just now') throw new Error(`a fresh answer says "${await text(page, '#an-depth')}"`);
    if (!/^The best play is .+: [\d.]+% wins, [\d.]+% gammons, [\d.]+% gammons against\.$/.test(await text(page, '#an-answer .rp-words')))
      throw new Error(`the best play in words: "${await text(page, '#an-answer .rp-words')}"`);
    const rows = await page.locator('#an-candidates .rp-cand').count();
    if (rows < 2 || rows > 5) throw new Error(`the table has ${rows} rows`);
    await still('the answer');

    // A candidate on the board, and the dice take it back.
    const board = async () => page.$eval('#an-board .bg-still', (el) => el.innerHTML);
    const asSetUp = await board();
    await page.click('#an-candidates .rp-cand[data-rank="2"]');
    if ((await text(page, '#an-proposed')) !== "ENGINE'S #2") throw new Error('the second play is not named on the board');
    if ((await board()) === asSetUp) throw new Error('the second play did not go on the board');
    await still('a candidate on the board');
    // The dice dim while the play they made is on the board (after their fade).
    await page.waitForTimeout(300);
    const dim = await page.$$eval('#an-board .die', (ds) => ds.map((d) => Number(getComputedStyle(d).opacity)));
    if (!dim.length || dim.some((o) => o > 0.6)) throw new Error(`the dice are not dimmed under a candidate: ${JSON.stringify(dim)}`);
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-06-candidate.png` });
    await page.click('#an-dice-toggle');
    if (await page.$('#an-proposed')) throw new Error('the dice did not take the play back');
    if ((await board()) !== asSetUp) throw new Error('the board is not the position set up after the dice');
    await still('taken back');

    // Asked again: free, and it says so.
    await page.click('#an-flip');
    await page.click('#an-flip');
    await analyze(page, (sel) => page.click(sel));
    if ((await text(page, '#an-depth')) !== '4-ply · already analyzed') throw new Error(`a second ask says "${await text(page, '#an-depth')}"`);
    await still('asked again');

    // A change to the position clears the answer.
    await page.click('#an-ask-double');
    if (await page.$('#an-answer')) throw new Error('DOUBLE? left the old answer up');
    if (!(await page.$('#an-panel .an-panel-hint'))) throw new Error('the cleared panel is not back to its hint');
    await still('cleared');
    log('verdict: the plate, the answer, a candidate on the board and back, already analyzed, cleared by an edit; nothing moved');

    // 7. The opening 3-1.
    await open(page, `/analysis?xgid=${encodeURIComponent(OPENING_31)}`);
    await analyze(page, (sel) => page.click(sel));
    const first = await text(page, '#an-candidates .rp-cand[data-rank="1"] .rp-cand-move');
    if (!first.startsWith('8/5 6/5')) throw new Error(`the opening 3-1's best play is "${first}"`);
    await page.click('#an-share');
    await page.waitForFunction(() => document.querySelector('#an-share-note')?.textContent.trim() === 'Link copied');
    const link = await page.evaluate(() => navigator.clipboard.readText());
    const m = link.match(new RegExp(`^${BASE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/puzzles/([A-Za-z0-9]+)$`));
    if (!m) throw new Error(`SHARE copied "${link}"`);
    const href = await page.getAttribute('#an-open-puzzle', 'href');
    if (href !== `/puzzles/${m[1]}` || (await page.getAttribute('#an-open-puzzle', 'target')) !== '_blank')
      throw new Error(`OPEN AS PUZZLE is ${href}`);
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-07-opening-31.png` });
    log(`the opening 3-1: 8/5 6/5 first; SHARE copied ${link}`);
    await stranger(browser, errors, link);

    // 8. DOUBLE?, and a roll that plays nothing.
    await open(page, `/analysis?xgid=${encodeURIComponent(OPENING_DOUBLE)}`);
    await page.click('#an-ask-double');
    const heldCube = await askedBoxes(page);
    await analyze(page, (sel) => page.click(sel));
    if ((await page.getAttribute('#an-answer', 'data-kind')) !== 'double') throw new Error('DOUBLE? is not answered as a double');
    if ((await page.locator('#an-answer .rp-cube-eq').count()) !== 3) throw new Error('the cube answer has no three equities');
    if ((await page.locator('#an-answer .rp-cube-eq.is-pick').count()) !== 1) throw new Error('the cube answer picks no one');
    sameAsked('the cube answer', heldCube, await askedBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-08-double.png` });

    await open(page, `/analysis?xgid=${encodeURIComponent(DANCE)}`);
    const heldDance = await askedBoxes(page);
    await analyze(page, (sel) => page.click(sel));
    if ((await text(page, '#an-refused-text')) !== '6-4 cannot be played from here') throw new Error(`a dance says "${await text(page, '#an-refused-text')}"`);
    if (await page.$('#an-retry')) throw new Error('a dance offers TRY AGAIN');
    sameAsked('a dance', heldDance, await askedBoxes(page));
    log('the cube: three equities and a pick; a dance says so with no TRY AGAIN');
  } finally {
    await context.close();
  }
}

// A stranger opens the shared link: the head is the question, naming nobody,
// and the page plays it to the reveal.
async function stranger(browser, errors, link) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, 'stranger', errors);
    const head = await (await page.request.get(link)).text();
    const title = (head.match(/property="og:title" content="([^"]*)"/) || [])[1];
    if (!['White to play 3-1. What&#39;s your play?', "White to play 3-1. What's your play?"].includes(title))
      throw new Error(`the shared link unfurls as "${title}": ${(head.match(/<meta[^>]*og:title[^>]*>/) || [head.slice(0, 1500)])[0]}`);
    if (/got this wrong/.test(head)) throw new Error('the shared link names somebody');
    await page.goto(link);
    await page.waitForSelector('.bg-point.source, .bg-bar.source');
    for (let i = 0; i < 6 && !(await page.locator('#bg-action-play').count()); i++) {
      await page.locator('.bg-point.source, .bg-bar.source').first().click();
    }
    await page.click('#bg-action-play');
    await page.waitForSelector('#pz-reveal');
    if ((await page.locator('#pz-candidates .rp-cand').count()) < 2) throw new Error('the reveal has no table');
    log('a stranger: the head asks the question and names nobody; the puzzle plays to its reveal');
  } finally {
    await context.close();
  }
}

// The panel at a size: empty, the answer, a candidate, cleared; nothing
// moves, the panel's own box included.
async function panelAt(browser, errors, tag, viewport) {
  const touch = viewport.width < 1024;
  const context = await browser.newContext({ viewport, hasTouch: touch, isMobile: touch });
  try {
    const page = settled(await context.newPage());
    watch(page, `panel ${tag}`, errors);
    const press = (sel) => (touch ? page.tap(sel) : page.click(sel));
    await open(page, `/analysis?xgid=${encodeURIComponent(OPENING_31)}`);
    const held = await askedBoxes(page);
    await analyze(page, press);
    sameAsked(`panel ${tag} the answer`, held, await askedBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}-answer.png`, fullPage: true });
    await press('#an-candidates .rp-cand[data-rank="3"]');
    sameAsked(`panel ${tag} a candidate`, held, await askedBoxes(page));
    await press('#an-dice-toggle');
    await press('#an-ask-double');
    sameAsked(`panel ${tag} cleared`, held, await askedBoxes(page));
    await analyze(page, press);
    sameAsked(`panel ${tag} the cube`, held, await askedBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}-double.png`, fullPage: true });
    await noSideScroll(page, `panel ${tag}`);
    log(`panel ${tag}: empty, a move, a candidate, cleared, a double; nothing moved`);
  } finally {
    await context.close();
  }
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  try {
    // PART=2 runs part 2 alone (while working on the answer).
    if (process.env.PART !== '2') {
      await menu(browser, errors);
      await desktop(browser, errors);
      await phone(browser, errors);
      await aim(browser, errors, '320', { width: 320, height: 568 });
      await aim(browser, errors, '844x390', { width: 844, height: 390 });
      await doors(browser, errors);
    }

    const stopEngine = await startEngine();
    try {
      await verdict(browser, errors);
      await panelAt(browser, errors, '390', { width: 390, height: 844 });
      await panelAt(browser, errors, '320', { width: 320, height: 568 });
      await panelAt(browser, errors, '844x390', { width: 844, height: 390 });
      await panelAt(browser, errors, 'desktop', { width: 1440, height: 900 });
    } finally {
      stopEngine();
    }
    if (errors.length) throw new Error(`console errors:\n${errors.join('\n')}`);
    log('ALL PASSED');
  } catch (e) {
    console.error(e);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
