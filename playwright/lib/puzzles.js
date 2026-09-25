/**
 * The ways through a puzzle, for the smokes that open one: reading the
 * sign-in mail the dev server "sent", staging a roll on the puzzle board,
 * and playing a whole run to its end screen.
 */
const { BASE } = require('./flows');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The last sign-in the dev server mailed for `email` (`/dev/last-login`). */
async function mailFor(request, email) {
  for (let i = 0; i < 50; i++) {
    const res = await request.get(`${BASE}/dev/last-login`);
    if (res.ok()) {
      const body = await res.json();
      if (body.email === email) return body;
    }
    await sleep(200);
  }
  throw new Error(`no sign-in mail for ${email}`);
}

/** Stage the whole roll: a tap on a source point plays it with the next
 * die, as at the table, until PLAY is offered. */
async function stageATurn(page) {
  // The legal moves are marked once the tree is in (a lazy one arrives a
  // level at a time): wait for the first source rather than read a board
  // that has not been told them yet.
  await page.waitForSelector('#bg-action-play, .bg-point.source, [data-move-source]', { timeout: 10000 });
  for (let i = 0; i < 6; i++) {
    if (await page.locator('#bg-action-play').count()) return;
    // A point marks itself `source`; the bar and the tray mark themselves
    // `data-move-source` (a checker entering from the bar has no point).
    const source = page.locator('.bg-point.source, [data-move-source]');
    if (!(await source.count())) throw new Error('the board offers no checker to move');
    await source.first().click();
    await sleep(150);
  }
  if (!(await page.locator('#bg-action-play').count())) throw new Error('PLAY is not offered once the roll is played');
}

/**
 * Play a run from the puzzle it is on to its end screen: stage, PLAY,
 * NEXT, until `#pz-end`. `onReveal(page, n)` is called at each reveal.
 * Resolves with how many puzzles were answered.
 */
async function playRun(page, { onReveal = async () => {}, max = 40 } = {}) {
  let answered = 0;
  for (let i = 0; i < max; i++) {
    await page.waitForSelector('#pz-board .bg-stack, #pz-end', { timeout: 15000 });
    if (await page.locator('#pz-end').count()) return answered;
    if (await page.locator('#pz-bands').count()) {
      // a cube question: any band answers it
      await page.locator('#pz-bands .pz-band').first().click();
    } else {
      await stageATurn(page);
      await page.click('#bg-action-play');
    }
    await page.waitForSelector('#pz-reveal', { timeout: 15000 });
    answered += 1;
    await onReveal(page, answered);
    await pressNext(page);
  }
  throw new Error(`the run did not end within ${max} puzzles`);
}

/**
 * On, until the page has moved: ANOTHER to the next mistake's URL, or,
 * where the run has no other, I'M DONE to the end screen on this one.
 * The reveal keeps filling in after the buttons appear (the memory line
 * lands a request later and pushes them down), so a click aimed a frame
 * earlier can land beside one; a click that moved nothing is made again.
 */
async function pressNext(page) {
  const was = new URL(page.url()).pathname;
  const moved = (from) => new URL(location.href).pathname !== from || !!document.querySelector('#pz-end');
  for (let i = 0; i < 4; i++) {
    await page.waitForSelector('#pz-next, #pz-done', { timeout: 5000 });
    const on = (await page.locator('#pz-next').count()) ? '#pz-next' : '#pz-done';
    await page.click(on);
    const ok = await page.waitForFunction(moved, was, { timeout: 3000 }).then(() => true, () => false);
    if (ok) return;
  }
  throw new Error(`neither ANOTHER nor I'M DONE moved anything at ${page.url()}`);
}

module.exports = { mailFor, stageATurn, playRun, pressNext, sleep };
