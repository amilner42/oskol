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
 * Part 4, SAVE, with an account arranged by account.exs (a browser signed
 * into it, none of its sets left from a run before):
 *
 * 10. A guest's SAVE is "Sign in to keep this position." over the sign-in
 * 11. No sets yet, at every size: the sheet floats over the answer and
 *     nothing under it moves
 * 12. A new set "Openings I like" made from the sheet with the position in
 *     it; a row unticked and ticked (the check moves at once, the line says
 *     where); a name already taken refused in the server's words; nothing
 *     in the sheet moves
 * 13. On /puzzles under "Your sets" after the five; TRAIN it to one
 *     reveal, whose SAVE has the set ticked
 * 14. The sheet, the hub and the set's page at every size, the delete
 *     confirm in its own slot
 * 15. The set's page: noindex, the position with its 72px board and its
 *     level, renamed, the position taken out, the set deleted (back to
 *     /puzzles, and its page gone)
 *
 * Screenshots at 390x844, 320x568, 844x390 and 1440x900 go to
 * playwright/screenshots/analysis-*.png (and puzzles-your-sets-*,
 * practice-own-*, puzzle-save-* for part 4).
 *
 * Run with the server up:  node playwright/test-analysis/test.js
 * Or on its own port:      playwright/test-analysis/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { spawn, execSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { stageATurn } = require('../lib/puzzles');

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
  '#an-off-white', '#an-off-black', '#an-left-white', '#an-left-black',
];

async function boxes(page) {
  return page.evaluate((sels) => {
    // Measured at the top of the page: the board is sticky sideways, so
    // where it sits depends on the scroll, not on the layout.
    const sx = window.scrollX, sy = window.scrollY;
    window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    window.scrollTo({ left: sx, top: sy, behavior: 'instant' });
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
  // A whole page is shot from its top: sideways the board is sticky, and a
  // page shot while scrolled would draw it halfway down.
  const screenshot = page.screenshot.bind(page);
  page.screenshot = async (opts = {}) => {
    if (opts.fullPage) { await page.evaluate(() => window.scrollTo({ left: 0, top: 0, behavior: 'instant' })); await settle(page); }
    return screenshot(opts);
  };
  return page;
}

const xgid = async (page) => { await settle(page); return page.inputValue('#an-xgid'); };

const field = (id, n) => id.slice(5).split(':')[n];

// A place's count as the board draws it, numbered as an id numbers them:
// White positive, Black negative; 0 is Black's bar, 25 White's. Read off
// the board, not the id: while a checker is not placed there is no id.
async function boardCount(page, index) {
  await settle(page);
  const sel = index === 0 ? '#an-bar-black' : index === 25 ? '#an-bar-white' : `#an-pt-${index}`;
  const d = await drawnOn(page, sel);
  return d.white - d.black;
}

async function expectCount(page, tag, index, want) {
  const got = await boardCount(page, index);
  if (got !== want) throw new Error(`${tag}: index ${index} holds ${got}, not ${want}`);
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
// Which one shows is the browser's pointer media (CI's headless Chromium on
// Linux reports a fine pointer even for a touch phone), so the check takes
// whichever is drawn -- and it must be whole either way.
async function hintFits(page, tag) {
  let seen = 0;
  for (const hint of ['.an-hint-touch', '.an-hint-mouse']) {
    const shown = await page.$eval(hint, (el) => el.offsetParent !== null && getComputedStyle(el).visibility !== 'hidden');
    if (shown) { seen++; await fits(page, tag, hint); }
  }
  if (seen !== 1) throw new Error(`${tag}: ${seen} hints show`);
}

// A mouse in a phone-wide window draws the mouse's hint whatever the font:
// it must be whole down to 320.
async function mouseHints(browser, errors) {
  for (const width of [480, 430, 390, 360, 320]) {
    const context = await browser.newContext({ viewport: { width, height: 844 } });
    try {
      const page = settled(await context.newPage());
      watch(page, `mouse ${width}`, errors);
      await open(page);
      if (!(await page.$eval('.an-hint-mouse', (el) => el.offsetParent !== null))) throw new Error(`${width}: a mouse does not get the mouse's hint`);
      await hintFits(page, `a mouse at ${width}`);
      await page.click('#an-brush-remove');
      await hintFits(page, `a mouse at ${width}, the x`);
    } finally {
      await context.close();
    }
  }
  log('a mouse in a narrow window: its hint whole at 480, 430, 390, 360 and 320');
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
    // Nothing placed: no id yet, and nothing to copy.
    if ((await xgid(page)) !== '') throw new Error(`CLEAR left the id ${await xgid(page)}`);
    if ((await page.getAttribute('#an-xgid', 'placeholder')) !== 'Place every checker first') throw new Error('the empty id field does not say why');
    if (!(await page.isDisabled('#an-xgid-copy'))) throw new Error('COPY is on with checkers not placed');
    if (await page.isDisabled('#an-xgid-import')) throw new Error('IMPORT is off with checkers not placed');
    await expectLine(page, 'cleared', 'Place 15 more White and 15 more Black checkers');
    if ((await page.innerText('#an-left-white')).trim() !== '15') throw new Error("White's brush does not say 15 to place");
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

    // A checker taken off is not placed, not borne off; the tray bears it
    // off on purpose, and gives it back.
    await page.click('#an-dice');
    await page.click('#an-roll-31');
    await page.click('#an-brush-remove');
    await page.click('#an-pt-6');
    await expectLine(page, 'one taken off', 'Place 1 more White checker');
    if (!(await page.isDisabled('#an-analyze'))) throw new Error('ANALYZE is on with a checker not placed');
    if ((await page.innerText('#an-left-white')).trim() !== '1') throw new Error("White's brush does not say 1 to place");
    await page.click('#an-brush-white');
    await page.click('#an-off-white');
    if ((await page.innerText('#an-off-white .off-words')).trim() !== '1 off') throw new Error(`White's tray says ${await page.innerText('#an-off-white')}`);
    await expectLine(page, 'borne off', '');
    if (await page.isDisabled('#an-analyze')) throw new Error('ANALYZE is off with every checker placed or off');
    await page.click('#an-off-white', { button: 'right' });
    await expectLine(page, 'taken back', 'Place 1 more White checker');
    await page.click('#an-pt-6');
    if ((await xgid(page)).split(':')[0].slice(5) !== OPENING.split(':')[0].slice(5)) throw new Error(`the checker did not go back: ${await xgid(page)}`);
    await page.waitForTimeout(800); // the sixteenth's flash, a moment ago, done
    await page.screenshot({ path: `${SHOTS}/analysis-desktop-02b-tray.png` });
    await still('the trays');

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
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: `${SHOTS}/analysis-390-01b-building.png`, fullPage: true });

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
      for (let p = 1; p <= 24; p++) {
        const want = p >= half[0] && p <= half[1] ? 1 : 0;
        if ((await boardCount(page, p)) !== want) throw new Error(`${tag}: taps on points ${half[0]}..${half[1]} left ${await boardCount(page, p)} on ${p}`);
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
    // Measured at the top of the page: the board is sticky sideways, so
    // where it sits depends on the scroll, not on the layout.
    const sx = window.scrollX, sy = window.scrollY;
    window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    out.pageHeight = document.documentElement.scrollHeight;
    window.scrollTo({ left: sx, top: sy, behavior: 'instant' });
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

// ---------- Part 3: playing it out ----------

// The boxes that hold all along the line: the board, the row over it (the
// brushes' box, PLAY's row in it), the head's SET UP / PLAY, the strip, the
// line and its arrows, ANALYZE's slot and the panel.
const LINE_HELD = [
  '#an-board', '.an-brushes', '#an-modes', '#an-strip', '.an-line-wrap', '#an-line', '#an-plates',
  '#an-first', '#an-prev', '#an-next', '#an-last', '.an-analyze', '#an-panel',
];

async function lineBoxes(page) {
  await settle(page);
  return page.evaluate((sels) => {
    // Measured at the top of the page: the board is sticky sideways, so
    // where it sits depends on the scroll, not on the layout.
    const sx = window.scrollX, sy = window.scrollY;
    window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x + window.scrollX, r.y + window.scrollY, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    out.pageHeight = document.documentElement.scrollHeight;
    window.scrollTo({ left: sx, top: sy, behavior: 'instant' });
    return out;
  }, LINE_HELD);
}

function sameLine(tag, before, after) {
  for (const s of [...LINE_HELD, 'pageHeight']) {
    if (JSON.stringify(before[s]) !== JSON.stringify(after[s]))
      throw new Error(`${tag}: ${s} moved from ${JSON.stringify(before[s])} to ${JSON.stringify(after[s])}`);
  }
}

const plates = (page) => page.$$eval('#an-plates .an-plate', (ps) => ps.map((p) => p.textContent.trim()));
const onPlate = (page) => page.$$eval('#an-plates .an-plate', (ps) => ps.findIndex((p) => p.classList.contains('is-on')));

async function expectPlates(page, tag, want) {
  await settle(page);
  const got = await plates(page);
  const ok = got.length === want.length && want.every((w, i) => (w instanceof RegExp ? w.test(got[i]) : w === got[i]));
  if (!ok) throw new Error(`${tag}: the line reads ${JSON.stringify(got)}, not ${want.map(String).join(' | ')}`);
}

// The table is up for the step on the board: its legal plays are in.
async function tableUp(page) {
  await page.waitForFunction(() => {
    const h = document.querySelector('#an-play-hint');
    return h && /then PLAY|PLAY passes/.test(h.textContent);
  }, null, { timeout: 15000 });
  await settle(page);
}

// Stage the whole roll on the table, a tap on a source per die, and PLAY.
async function playByHand(page, press) {
  for (let i = 0; i < 6; i++) {
    if (await page.locator('#bg-action-play').count()) break;
    const source = page.locator('.bg-point.source, .bg-bar.source');
    if (!(await source.count())) throw new Error('the table offers no checker to move');
    await press(source.first());
    await page.waitForTimeout(120);
  }
  if (!(await page.locator('#bg-action-play').count())) throw new Error('PLAY is not offered once the roll is played');
  await press(page.locator('#bg-action-play'));
}

// PLAY locks what edits the position and leaves what reads it.
async function lockedInPlay(page, tag, locked) {
  await settle(page);
  const state = await page.evaluate(() => ({
    strip: document.querySelector('#an-strip').disabled,
    cube: document.querySelector('#an-cube').matches(':disabled'),
    opening: document.querySelector('#an-opening').matches(':disabled'),
    imp: document.querySelector('#an-xgid-import').disabled,
    copy: document.querySelector('#an-xgid-copy').disabled,
    id: document.querySelector('#an-xgid').value,
  }));
  const want = { strip: locked, cube: locked, opening: locked, imp: locked, copy: false };
  for (const k of Object.keys(want)) {
    if (state[k] !== want[k]) throw new Error(`${tag}: in ${locked ? 'PLAY' : 'SET UP'} ${k} is ${state[k] ? 'disabled' : 'live'}`);
  }
  if (!state.id.startsWith('XGID=')) throw new Error(`${tag}: the id is "${state.id}" in ${locked ? 'PLAY' : 'SET UP'}`);
}

async function playItOut(browser, errors, tag, viewport) {
  const touch = viewport.width < 1024;
  const context = await browser.newContext({ viewport, hasTouch: touch, isMobile: touch });
  try {
    const page = settled(await context.newPage());
    watch(page, `line ${tag}`, errors);
    const press = async (target) => {
      const loc = typeof target === 'string' ? page.locator(target) : target;
      await (touch ? loc.tap() : loc.click());
      await settle(page);
    };
    // Nothing on the way asks the engine but ANALYZE.
    let asks = 0;
    page.on('request', (r) => { if (/\/papi\/analysis$/.test(new URL(r.url()).pathname) && r.method() === 'POST') asks += 1; });

    await open(page, `/analysis?xgid=${encodeURIComponent(OPENING_31)}`);
    const held = await lineBoxes(page);
    await expectPlates(page, `${tag} the start`, ['W 3-1']);
    if (!(await page.$('#an-first:disabled')) || !(await page.$('#an-last:disabled'))) throw new Error(`${tag}: one step and the arrows are live`);

    // The best 3-1, played.
    await analyze(page, press);
    if ((await text(page, '#an-play-candidate')) !== 'PLAY BEST') throw new Error(`${tag}: PLAY BEST is not offered`);
    await press('#an-play-candidate');
    await expectPlates(page, `${tag} the best 3-1`, ['W 3-1 · 8/5 6/5', 'B to roll']);
    if ((await onPlate(page)) !== 1) throw new Error(`${tag}: the board is not on Black's step`);
    if (!(await page.$('#an-mode-play.is-on'))) throw new Error(`${tag}: playing did not put the board in PLAY`);
    sameLine(`${tag} played`, held, await lineBoxes(page));
    if (tag === '390') await page.screenshot({ path: `${SHOTS}/analysis-${tag}-line-01-played.png`, fullPage: true });

    // ROLL FOR ME for Black, the table on its legal plays, and ANALYZE.
    await press('#an-roll-random');
    await expectPlates(page, `${tag} rolled`, ['W 3-1 · 8/5 6/5', /^B [1-6]-[1-6]$/]);
    await tableUp(page);
    sameLine(`${tag} the table`, held, await lineBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}-line-02-table.png`, fullPage: true });
    const before = asks;
    await analyze(page, press);
    if (asks !== before + 1) throw new Error(`${tag}: ANALYZE asked ${asks - before} times`);
    if (!(await page.$('#an-answer'))) throw new Error(`${tag}: Black's roll was not answered`);
    sameLine(`${tag} Black analyzed`, held, await lineBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}-line-03-black.png`, fullPage: true });

    // Back to the opening and forward again: no fetch, the answers kept.
    const walking = asks;
    await press('#an-first');
    if ((await onPlate(page)) !== 0) throw new Error(`${tag}: FIRST is not the opening`);
    if (!(await page.$('#an-answer'))) throw new Error(`${tag}: the opening's answer is gone`);
    if ((await page.inputValue('#an-xgid')) !== OPENING_31) throw new Error(`${tag}: step 0 is ${await page.inputValue('#an-xgid')}`);
    if (!(await page.$('#an-candidates .rp-cand[data-rank="1"]'))) throw new Error(`${tag}: the opening's candidates are gone`);
    sameLine(`${tag} back to the opening`, held, await lineBoxes(page));
    await press('#an-next');
    if ((await onPlate(page)) !== 1) throw new Error(`${tag}: NEXT is not Black's step`);
    if (!(await page.$('#an-answer'))) throw new Error(`${tag}: Black's answer is gone`);
    if (asks !== walking) throw new Error(`${tag}: walking the line asked the engine`);
    sameLine(`${tag} forward`, held, await lineBoxes(page));

    // Black plays by hand on the table (Black at the bottom), then White
    // doubles and Black passes: the line ends in its sentence.
    await press('#an-mode-play');
    await tableUp(page);
    await playByHand(page, press);
    await expectPlates(page, `${tag} by hand`, ['W 3-1 · 8/5 6/5', /^B [1-6]-[1-6] · \S/, 'W to roll']);
    // In PLAY the position is not edited: the strip, the quick starts and
    // IMPORT are disabled where they stand (the boxes are held above); the
    // id and COPY still read the step on the board. The row over the board
    // offers what a player on roll can do.
    await lockedInPlay(page, tag, true);
    for (const sel of ['#an-roll-random', '#an-roll-pick', '#an-roll-double']) {
      if (!(await page.isVisible(sel))) throw new Error(`${tag}: White to roll has no ${sel}`);
    }
    await press('#an-roll-double');
    await expectPlates(page, `${tag} double?`, ['W 3-1 · 8/5 6/5', /^B /, 'W double?']);
    await press('#an-cube-yes');
    await press('#an-pass');
    await expectPlates(page, `${tag} passed`, ['W 3-1 · 8/5 6/5', /^B /, 'W doubles', 'B passes']);
    if ((await text(page, '#an-line-end')) !== 'Black passes. White wins 1 point.') throw new Error(`${tag}: the line ends "${await text(page, '#an-line-end')}"`);
    sameLine(`${tag} passed`, held, await lineBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-${tag}-line-04-passed.png`, fullPage: true });

    // A different move at step 1 drops what came after it.
    await press('#an-plate-0');
    await press('#an-candidates .rp-cand[data-rank="3"]');
    await press('#an-play-candidate');
    await expectPlates(page, `${tag} another 3-1`, [/^W 3-1 · (?!8\/5 6\/5$)/, 'B to roll']);
    sameLine(`${tag} another 3-1`, held, await lineBoxes(page));

    // PICK A ROLL: the sheet, in PLAY, picks Black's roll; the table follows.
    await press('#an-roll-pick');
    await page.waitForSelector('#an-roll-sheet');
    await press('#an-roll-52');
    await expectPlates(page, `${tag} a roll picked`, [/^W 3-1 · /, 'B 5-2']);
    await tableUp(page);
    sameLine(`${tag} a roll picked`, held, await lineBoxes(page));

    // SET UP at a later step: an edit starts a fresh line from it.
    await press('#an-mode-setup');
    await lockedInPlay(page, tag, false);
    await press('#an-turn-white');
    // (the roll picked for Black stays the ask; only the side changed)
    await expectPlates(page, `${tag} a fresh line`, ['W 5-2']);
    sameLine(`${tag} a fresh line`, held, await lineBoxes(page));
    await noSideScroll(page, `line ${tag}`);
    log(`line ${tag}: the best 3-1, ROLL FOR ME, analyzed, back and forward with no fetch, by hand (the strip locked), a pass, PICK A ROLL; nothing moved`);
  } finally {
    await context.close();
  }
}

// ---------- Part 4: SAVE, and your sets ----------

/** An account with no sets yet (account.exs), and its guest cookie. */
function accountFixture() {
  return JSON.parse(
    resultLine(
      execSync(`mix run -e 'Code.eval_file("playwright/test-analysis/account.exs")'`, {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'inherit'],
      })
    )
  );
}

// The sheet's own boxes: nothing in it moves while the list loads, a row
// is ticked, a set is made or a name refused.
const SHEET = ['.save-sheet', '#save-sets', '#save-new-name', '#save-create', '#save-line'];

async function sheetBoxes(page) {
  return page.evaluate((sels) => {
    const out = {};
    for (const s of sels) {
      const el = document.querySelector(s);
      if (!el) { out[s] = null; continue; }
      const r = el.getBoundingClientRect();
      out[s] = [r.x, r.y, r.width, r.height].map((n) => Math.round(n * 2) / 2);
    }
    return out;
  }, SHEET);
}

function sameSheet(tag, before, after) {
  for (const s of SHEET) {
    if (JSON.stringify(before[s]) !== JSON.stringify(after[s]))
      throw new Error(`${tag}: ${s} moved from ${JSON.stringify(before[s])} to ${JSON.stringify(after[s])}`);
  }
}

async function lineSays(page, want) {
  await page.waitForFunction(
    (w) => document.querySelector('#save-line')?.textContent.trim() === w,
    want, { timeout: 10000 }
  ).catch(async () => {
    throw new Error(`the save line says "${await text(page, '#save-line')}", not "${want}"`);
  });
}

const checkedOf = (page, id) => page.getAttribute(`#save-set-${id}`, 'aria-checked');

const VIEWPORTS = [
  ['390', { width: 390, height: 844 }, true],
  ['320', { width: 320, height: 568 }, true],
  ['844x390', { width: 844, height: 390 }, true],
  ['desktop', { width: 1440, height: 900 }, false],
];

async function accountPage(browser, fixture, viewport, touch, errors, who) {
  const context = await seatedContext(browser, fixture.guest_id, { viewport, hasTouch: touch, isMobile: touch });
  const page = settled(await context.newPage());
  watch(page, who, errors);
  const press = touch ? (sel) => page.tap(sel) : (sel) => page.click(sel);
  return { context, page, press };
}

/** The opening 3-1, answered (free: asked already). */
async function answeredOpening(page, press) {
  await open(page, `/analysis?xgid=${encodeURIComponent(OPENING_31)}`);
  await analyze(page, press);
  if (!(await page.$('#an-save'))) throw new Error('the answer has no SAVE');
}

// 10. A guest's SAVE is the sign-in, nothing else.
async function guestSave(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  try {
    const page = settled(await context.newPage());
    watch(page, 'guest save', errors);
    await answeredOpening(page, (sel) => page.tap(sel));
    const held = await askedBoxes(page);
    await page.tap('#an-save');
    await page.waitForSelector('#save-modal #signin-email');
    if ((await text(page, '#save-signin-line')) !== 'Sign in to keep this position.') throw new Error('the guest is not asked to sign in');
    if (await page.$('#save-sets')) throw new Error('a guest is shown sets');
    sameAsked('a guest opening the sheet', held, await askedBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-save-guest-390.png` });
    await page.tap('#save-close');
    await page.waitForSelector('#save-modal', { state: 'detached' });
    sameAsked('a guest closing the sheet', held, await askedBoxes(page));
    log('a guest: SAVE is "Sign in to keep this position." over the sign-in; nothing under it moved');
  } finally {
    await context.close();
  }
}

// 11. No sets yet, at every size: the sheet floats and nothing under it moves.
async function emptySheets(browser, errors, fixture) {
  for (const [tag, viewport, touch] of VIEWPORTS) {
    const { context, page, press } = await accountPage(browser, fixture, viewport, touch, errors, `empty ${tag}`);
    try {
      await answeredOpening(page, press);
      const held = await askedBoxes(page);
      await press('#an-save');
      await page.waitForSelector('#save-modal #save-empty');
      sameAsked(`${tag}: the sheet opening`, held, await askedBoxes(page));
      await noSideScroll(page, `${tag}: the sheet`);
      await page.screenshot({ path: `${SHOTS}/analysis-save-empty-${tag}.png` });
      await press('#save-close');
      await page.waitForSelector('#save-modal', { state: 'detached' });
      sameAsked(`${tag}: the sheet closing`, held, await askedBoxes(page));
    } finally {
      await context.close();
    }
  }
  log('no sets yet: the sheet at 390, 320, 844x390 and desktop; nothing under it moved');
}

// 12. Make a set and save into it; untick, tick; a name already taken.
async function makeASet(browser, errors, fixture) {
  const { context, page } = await accountPage(browser, fixture, { width: 390, height: 844 }, true, errors, 'save');
  try {
    await answeredOpening(page, (sel) => page.tap(sel));
    const puzzleId = (await page.getAttribute('#an-open-puzzle', 'href')).replace('/puzzles/', '');
    await page.tap('#an-save');
    await page.waitForSelector('#save-modal #save-empty');
    const sheet = await sheetBoxes(page);
    await page.fill('#save-new-name', 'Openings I like');
    await page.screenshot({ path: `${SHOTS}/analysis-save-naming-390.png` });
    await page.tap('#save-create');
    await lineSays(page, 'Saved to Openings I like · 1 position');
    const setId = (await page.getAttribute('#save-sets .save-set', 'id')).replace('save-set-', '');
    if ((await checkedOf(page, setId)) !== 'true') throw new Error('the new set is not ticked');
    if ((await page.inputValue('#save-new-name')) !== '') throw new Error('the name stayed in the field');
    sameSheet('a set made', sheet, await sheetBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-save-saved-390.png` });

    // A tap inks (or clears) the check at once; the answer says where.
    await page.tap(`#save-set-${setId}`);
    if ((await checkedOf(page, setId)) !== 'false') throw new Error('unticking did not clear the check at once');
    await lineSays(page, 'Taken out of Openings I like · 0 positions');
    await page.tap(`#save-set-${setId}`);
    if ((await checkedOf(page, setId)) !== 'true') throw new Error('ticking did not ink the check at once');
    await lineSays(page, 'Saved to Openings I like · 1 position');
    sameSheet('ticked and unticked', sheet, await sheetBoxes(page));

    // The same name again, in another case: refused, in the server's words.
    await page.fill('#save-new-name', 'openings i like');
    await page.tap('#save-create');
    await lineSays(page, 'You already have a set called that');
    if (!(await page.$('#save-line.is-refused'))) throw new Error('the refusal is not drawn as one');
    if ((await page.locator('#save-sets .save-set').count()) !== 1) throw new Error('a refused name made a set');
    sameSheet('a name refused', sheet, await sheetBoxes(page));
    await page.screenshot({ path: `${SHOTS}/analysis-save-refused-390.png` });
    await page.tap('#save-close');
    await page.waitForSelector('#save-modal', { state: 'detached' });

    // Opened again: the set is there, ticked, read from the server.
    await page.tap('#an-save');
    await page.waitForSelector(`#save-set-${setId}`);
    if ((await checkedOf(page, setId)) !== 'true') throw new Error('opened again, the set does not hold the position');
    await page.tap('#save-close');
    log(`made "Openings I like" (${setId}) from the sheet with ${puzzleId} in it; untick, tick and a taken name; the sheet held still`);
    return { setId, puzzleId };
  } finally {
    await context.close();
  }
}

// 13. On /puzzles after the five; TRAIN it to one reveal, whose SAVE knows.
async function trainIt(browser, errors, fixture, setId) {
  const { context, page } = await accountPage(browser, fixture, { width: 390, height: 844 }, true, errors, 'train');
  try {
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-your-sets');
    const order = await page.$$eval('#hub-rows > *', (els) => els.map((e) => e.id));
    const at = order.indexOf('hub-your-sets');
    // After every deck on offer (the five, or as many as this database has built).
    if (at < 3 || at !== order.length - 2 || order[at + 1] !== `hub-slot-${setId}`) throw new Error(`"Your sets" is not after the five: ${order.join(', ')}`);
    // Closed, a row (its name, how many are left); a press opens it in
    // place. The server may lead with it (the account's only work), open.
    if (!(await page.$(`#hub-card[data-deck="${setId}"]`))) {
      const row = await text(page, `#hub-row-${setId}`);
      if (!row.includes('Openings I like') || !row.includes('1 left')) throw new Error(`the row says "${row}"`);
      await page.screenshot({ path: `${SHOTS}/puzzles-your-sets-row-390.png`, fullPage: true });
      await page.tap(`#hub-row-${setId}`);
    }
    await page.waitForSelector(`#hub-card[data-kind="own"][data-deck="${setId}"]`);
    if ((await text(page, '#hub-name')) !== 'Openings I like') throw new Error('the card does not name the set');
    if ((await text(page, '#hub-go')) !== 'TRAIN') throw new Error(`the set's button says ${await text(page, '#hub-go')}`);
    await page.waitForTimeout(700); // the drawer's slide
    await page.screenshot({ path: `${SHOTS}/puzzles-your-sets-card-390.png`, fullPage: true });
    await page.tap('#hub-go');
    await page.waitForURL(/\/puzzles\/[A-Za-z0-9]+$/);
    await page.waitForSelector('#pz-board .bg-stack');
    await stageATurn(page);
    await page.tap('#bg-action-play');
    await page.waitForSelector('#pz-reveal', { timeout: 15000 });
    await page.tap('#pz-save');
    await page.waitForSelector(`#save-set-${setId}`);
    if ((await checkedOf(page, setId)) !== 'true') throw new Error('the reveal\'s SAVE does not know the set holds it');
    await page.screenshot({ path: `${SHOTS}/puzzle-save-390.png` });
    await page.tap('#save-close');
    log('the set on /puzzles after the five, TRAIN, one reveal, and its SAVE has the check');
  } finally {
    await context.close();
  }
}

// 14. The sheet, the hub and the set's page at every size.
async function everySize(browser, errors, fixture, setId) {
  for (const [tag, viewport, touch] of VIEWPORTS) {
    const { context, page, press } = await accountPage(browser, fixture, viewport, touch, errors, `sizes ${tag}`);
    try {
      await answeredOpening(page, press);
      const held = await askedBoxes(page);
      await press('#an-save');
      await page.waitForSelector(`#save-set-${setId}`);
      sameAsked(`${tag}: the sheet over the answer`, held, await askedBoxes(page));
      await noSideScroll(page, `${tag}: the sheet`);
      await page.screenshot({ path: `${SHOTS}/analysis-save-sets-${tag}.png` });

      await page.goto(`${BASE}/puzzles`);
      await page.waitForSelector(`#hub-row-${setId}, #hub-card[data-deck="${setId}"]`);
      if (await page.$(`#hub-row-${setId}`)) await press(`#hub-row-${setId}`);
      await page.waitForSelector('#hub-card[data-kind="own"]');
      await noSideScroll(page, `${tag}: the hub`);
      await page.waitForTimeout(700); // the drawer's slide
      await page.screenshot({ path: `${SHOTS}/puzzles-your-sets-${tag}.png`, fullPage: true });

      await page.goto(`${BASE}/practice/${setId}`);
      await page.waitForSelector('#practice-manage .dp-member');
      await noSideScroll(page, `${tag}: the set's page`);
      const before = await page.$eval('#practice-delete-slot', (el) => el.getBoundingClientRect().height);
      await press('#practice-delete');
      await page.waitForSelector('#practice-delete-question');
      const after = await page.$eval('#practice-delete-slot', (el) => el.getBoundingClientRect().height);
      if (before !== after) throw new Error(`${tag}: the delete confirm changed its slot from ${before} to ${after}`);
      await page.screenshot({ path: `${SHOTS}/practice-own-${tag}.png`, fullPage: true });
      await press('#practice-delete-no');
      await page.waitForSelector('#practice-delete');
    } finally {
      await context.close();
    }
  }
  log('the sheet with the set, the hub with it open, and its page with MANAGE at every size');
}

// 15. MANAGE: rename, take the position out, delete the set.
async function manageIt(browser, errors, fixture, setId, puzzleId) {
  const { context, page } = await accountPage(browser, fixture, { width: 390, height: 844 }, true, errors, 'manage');
  try {
    await page.goto(`${BASE}/practice/${setId}`);
    await page.waitForSelector(`#practice-member-${puzzleId}`);
    if ((await page.getAttribute('meta[name="robots"]', 'content')) !== 'noindex') throw new Error('an own set\'s page is not noindex');
    const word = await text(page, `#practice-member-${puzzleId} .dp-member-level`);
    if (!['to learn', 'back at the start', 'level 1'].includes(word)) throw new Error(`the position stands at "${word}"`);
    if (!(await page.$(`#practice-member-${puzzleId} .dp-member-board .bg-still`))) throw new Error('the position has no small board');
    const boardBox = await page.$eval(`#practice-member-${puzzleId} .dp-member-board`, (el) => [el.offsetWidth, el.offsetHeight]);
    if (boardBox[1] !== 72) throw new Error(`the small board is ${boardBox[1]}px tall`);

    await page.fill('#practice-rename', 'Openings I love');
    await page.tap('#practice-rename-save');
    await page.waitForFunction(() => document.querySelector('#practice-manage-line')?.textContent.trim() === 'Renamed.');
    if ((await text(page, '#practice-name')) !== 'Openings I love') throw new Error('the card did not take the new name');

    await page.tap(`#practice-remove-${puzzleId}`);
    await page.waitForSelector('#practice-members-empty');
    await page.waitForSelector('#practice-open-analysis');
    await page.screenshot({ path: `${SHOTS}/practice-own-emptied-390.png`, fullPage: true });

    await page.tap('#practice-delete');
    await page.waitForSelector('#practice-delete-question');
    const q = await text(page, '#practice-delete-question');
    if (q !== 'Delete Openings I love? Its positions stay where they are; your progress on them is kept aside.') throw new Error(`the confirm says "${q}"`);
    await page.tap('#practice-delete-yes');
    await page.waitForURL(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-rows');
    if (await page.$('#hub-your-sets')) throw new Error('the deleted set is still on /puzzles');
    const gone = await page.goto(`${BASE}/practice/${setId}`);
    if (gone.status() !== 404) throw new Error(`a deleted set's page answers ${gone.status()}`);
    log(`MANAGE: renamed, the position taken out, the set deleted and gone (its page now ${gone.status()})`);
  } finally {
    await context.close();
  }
}

async function part4(browser, errors) {
  const fixture = accountFixture();
  await guestSave(browser, errors);
  await emptySheets(browser, errors, fixture);
  const { setId, puzzleId } = await makeASet(browser, errors, fixture);
  await trainIt(browser, errors, fixture, setId);
  await everySize(browser, errors, fixture, setId);
  await manageIt(browser, errors, fixture, setId, puzzleId);
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  try {
    // PART=2 runs parts 2 to 4, PART=3 or PART=4 that part alone (while
    // working on them).
    const part = process.env.PART || '1';
    if (part === '1') {
      await menu(browser, errors);
      await desktop(browser, errors);
      await phone(browser, errors);
      await mouseHints(browser, errors);
      await aim(browser, errors, '320', { width: 320, height: 568 });
      await aim(browser, errors, '844x390', { width: 844, height: 390 });
      await doors(browser, errors);
    }

    const stopEngine = await startEngine();
    try {
      if (part !== '3' && part !== '4') {
        await verdict(browser, errors);
        await panelAt(browser, errors, '390', { width: 390, height: 844 });
        await panelAt(browser, errors, '320', { width: 320, height: 568 });
        await panelAt(browser, errors, '844x390', { width: 844, height: 390 });
        await panelAt(browser, errors, 'desktop', { width: 1440, height: 900 });
      }
      if (part !== '4') {
        await playItOut(browser, errors, 'desktop', { width: 1440, height: 900 });
        await playItOut(browser, errors, '390', { width: 390, height: 844 });
        await playItOut(browser, errors, '320', { width: 320, height: 568 });
        await playItOut(browser, errors, '844x390', { width: 844, height: 390 });
      }
      if (part !== '3') await part4(browser, errors);
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
