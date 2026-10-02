/**
 * The practice home and a session, end to end. `test-puzzle/setup.exs`
 * arranges a finished game graded against a stubbed engine; Alice's seat
 * is then trimmed to twelve mistakes, so the numbers below are known:
 * a guest's session is all twelve, an account's first is the day's three
 * new (worst first), which is what one tier's TRAIN run holds.
 *
 *  1. A stranger (a fresh browser) opens /puzzles: what this is, TRY ONE,
 *     and TRY ONE opens a puzzle with no NEXT (one puzzle is not a run).
 *  2. Alice, a guest holding the seat that made the mistakes, opens
 *     /puzzles: "12 mistakes from your 1 game", that nothing is saved,
 *     her worst tier open with TRAIN. The run: that tier's
 *     puzzles, PLAY and NEXT each, then the score and the sign-in ask. She signs in right there (the mail read
 *     from /dev/last-login) and CONTINUE lands her back on /puzzles with
 *     a deck: the counts line, and her timezone sent once.
 *  3. As an account: five decks as drawers, one open -- the worst tier, by its
 *     mark, with its grid (a square a mistake), today's ring and TRAIN
 *     -- and the others as rows. Each row tapped in turn opens in its own
 *     slot: the five never reorder and nothing above the tapped row
 *     moves; back to the lead, the page is the height it was. TRAIN runs that tier -- the counter and the
 *     marks watched over each of them -- and ends on the summary with the
 *     way back. I'M DONE ends a run after one. Once today's set is done
 *     the ring is full and the one button is still there: KEEP GOING (or
 *     PRACTICE ANYWAY), which starts a run.
 *     The answer that finishes today's set brings the celebration under
 *     its reveal: the ring over the board a check, "Today's 3 done.", the
 *     tier's grid, KEEP GOING beside I'M DONE -- and nothing above it moves,
 *     measured as it lands and, at 390x844, 320x568, 844x390 and 1440x900,
 *     with the card against without it. KEEP GOING starts three more and
 *     the ring's target grows by them (3/6); ANOTHER takes that run to its
 *     end with no second card, and the end card offers the way on.
 *  4. Phones: the home at 390x844, 320x568 and 844x390 scrolls nowhere
 *     sideways.
 *  5. More due than a page holds (many_due.exs: 25 very bad moves due):
 *     the run goes on past the twentieth, and the strip over the board is
 *     the same box with one tile as with twenty-two.
 *
 * Run with the dev server up (/dev routes on):
 *   node playwright/test-puzzles-hub/test.js
 */
const playwright = require('playwright');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { pressNext, playRun } = require('../lib/puzzles');

const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const KEPT = 12;

// The pace, from `src/oskol/practice/deck.gleam`: three new mistakes a
// day, worst first. The numbers below are read off it and off KEPT.
const NEW_PER_DAY = 3;

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrange() {
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  const setup = JSON.parse(resultLine(out));
  // Trim the first seat's mistakes to a known count, oldest turns kept.
  const trim = `
    import Ecto.Query
    ids =
      Oskol.Repo.all(from(s in Oskol.Puzzles.Source,
        where: s.game_id == ${JSON.stringify(setup.game_id)} and s.player_id == ${JSON.stringify(setup.players[0].id)},
        order_by: s.turn, select: s.id))
    Oskol.Repo.delete_all(from(s in Oskol.Puzzles.Source, where: s.id in ^Enum.drop(ids, ${KEPT})))
    IO.puts(Jason.encode!(%{kept: min(length(ids), ${KEPT})}))
  `;
  const kept = JSON.parse(resultLine(execFileSync('mix', ['run', '-e', trim], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  }))).kept;
  must(kept === KEPT, `the first seat has ${KEPT} mistakes to practice (${kept})`);
  return setup;
}

/** The last sign-in the dev server mailed for `email`. */
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

/** Stage the whole roll, as at the table, until PLAY is offered. */
async function stageATurn(page) {
  // The board offers its legal moves a frame after it is drawn, and again
  // a frame after each tap: wait for them (or for PLAY, once the roll is
  // played) every step rather than counting what happens to be there. A
  // legal origin is marked `data-move-source`, on a point or the bar.
  for (let i = 0; i < 6; i++) {
    const next = await page.waitForSelector('#bg-action-play, [data-move-source]', { timeout: 10000 }).catch(() => null);
    if (!next) throw new Error(`the board offers no checker to move and no PLAY at ${page.url()}`);
    if (await page.locator('#bg-action-play').count()) return;
    await page.locator('[data-move-source]').first().click();
    await sleep(120);
  }
  if (!(await page.locator('#bg-action-play').count())) throw new Error(`PLAY is not offered once the roll is played at ${page.url()}`);
}

/** Answer whatever question is on the page: a cube question is five
 * bands (the middle one will do), a checker play is staged and PLAYed. */
async function answer(page) {
  await page.waitForSelector('#pz-bands, #bg-action-play, [data-move-source]', { timeout: 10000 });
  if (await page.locator('#pz-bands').count()) {
    await page.click('#pz-band-1');
    return;
  }
  await stageATurn(page);
  await page.click('#bg-action-play');
}

/** One puzzle of a run: answer it, see the reveal, press NEXT. */
async function answerAndNext(page, n) {
  // The previous puzzle's reveal leaves the DOM a frame after the URL
  // moved on; the new board is the one without it.
  await page.waitForSelector('#pz-reveal', { state: 'detached' });
  await page.waitForSelector('#pz-board .bg-stack');
  await answer(page);
  await page.waitForSelector('#pz-reveal');
  // The next puzzle is another URL, or the end screen on this one. The
  // reveal keeps filling in after NEXT appears (the memory line lands a
  // request later and pushes NEXT down), so a click aimed a frame earlier
  // can land beside it: `pressNext` clicks again if nothing moved.
  await pressNext(page);
  log(`puzzle ${n} answered`);
}

/** The strip over the board: the tier's mark, today's ring, the day's
 * count, and a tile for each mistake answered so far -- never one for a
 * mistake that may never be reached, because a run has no length. */
async function progressOf(page, seen) {
  const label = (await page.textContent('#pz-progress-label')).trim();
  const count = (await page.textContent('#pz-progress-count')).trim();
  const marks = await page.locator('#pz-marks [data-mark]').count();
  must(marks === seen, `a tile for each mistake reached so far (${marks} of ${seen})`);
  const ring = await page.locator('#pz-ring').count()
    ? { done: Number(await page.getAttribute('#pz-ring', 'data-done')), target: Number(await page.getAttribute('#pz-ring', 'data-target')) }
    : null;
  return {
    label,
    count,
    ring,
    strip: await page.evaluate(() => { const r = document.querySelector('#pz-progress').getBoundingClientRect(); return { y: Math.round(r.y), h: Math.round(r.height) }; }),
    filled: await page.locator('#pz-marks [data-mark]:not([data-mark="blank"])').count(),
    today: Number((count.match(/(\d+) practiced today/) || [0, 0])[1]),
  };
}

/** A whole run from its first puzzle to the end screen. */
async function runToEnd(page, expected) {
  for (let n = 1; n <= expected; n++) {
    await answerAndNext(page, n);
  }
  await page.waitForSelector('#pz-end');
  const score = (await page.textContent('#pz-score')).trim();
  must(new RegExp(`^\\d+ of ${expected} right$`).test(score), `the run ends on its score: "${score}"`);
  return score;
}

async function boxOf(page, selector) {
  return page.evaluate((s) => {
    const r = document.querySelector(s).getBoundingClientRect();
    return { y: Math.round(r.y), h: Math.round(r.height) };
  }, selector);
}

/** Where the things over the card sit in the page: each one's box with
 * every scroll between it and the page taken out, so a scroll is not a
 * move. */
function layoutOf(page) {
  return page.evaluate(() => {
    const at = (sel) => {
      const el = document.querySelector(sel);
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
    return { board: at('#pz-board'), strip: at('#pz-progress'), verdict: at('#pz-verdict'), level: at('#pz-level'), band: at('#pz-actions') };
  });
}

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

async function run(browser, setup, errors) {
  const contexts = [];
  const open = async (who, context) => {
    contexts.push(context);
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
    return page;
  };

  try {
    // ---- 1. a stranger ----
    const stranger = await open('stranger', await browser.newContext({ viewport: { width: 390, height: 844 } }));
    await stranger.goto(`${BASE}/puzzles`);
    const html = await stranger.content();
    must(/<title[^>]*>Puzzles · Oskol<\/title>/.test(html), 'the head is the practice home\'s');
    must(!html.includes('name="robots"'), 'the practice home is indexable');
    await stranger.waitForSelector('#puzzles-hub #hub-try-one');
    must(await stranger.locator('#hub-about').count(), 'a stranger is told what this is');
    must(!(await stranger.locator('#hub-card').count()), 'and nothing of hers is open');
    const strangerRows = await stranger.locator('#hub-rows .dk-row').count();
    must(strangerRows >= 3, `the decks are rows, her tiers among them (${strangerRows})`);
    await stranger.click('#hub-try-one');
    await stranger.waitForSelector('#pz-board .bg-stack');
    must(/^\/puzzles\/[0-9A-Z]{8}$/i.test(new URL(stranger.url()).pathname), `TRY ONE opened a puzzle: ${stranger.url()}`);
    // TRY ONE may hand out a cube question as readily as a checker play.
    await answer(stranger);
    await stranger.waitForSelector('#pz-reveal');
    must(!(await stranger.locator('#pz-next').count()), 'one puzzle is not a run: no ANOTHER');
    must(!(await stranger.locator('#pz-done').count()), "and nothing to be done with: no I'M DONE");

    // ---- 2. Alice, a guest with games behind her ----
    const aliceContext = await seatedContext(browser, setup.players[0].guest, { viewport: { width: 390, height: 844 } });
    const alice = await open('alice', aliceContext);
    const posts = [];
    alice.on('request', (r) => {
      if (r.method() === 'POST' && r.url().includes('/papi/practice/tz')) posts.push(r.postDataJSON());
    });
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-go[data-action="practice"]');
    const headline = (await alice.textContent('#hub-headline')).trim();
    must(headline === `${KEPT} mistakes from your 1 game`, `a guest reads what is hers: "${headline}"`);
    must(await alice.locator('#hub-unsaved').count(), 'and that nothing is saved yet');
    must(posts.length === 0, 'a guest\'s timezone is nobody\'s to keep');
    // Her worst tier is open, and TRAIN runs that tier.
    const guestTier = await alice.getAttribute('#hub-card', 'data-deck');
    const guestDecks = (await (await alice.request.get(`${BASE}/papi/practice/decks`)).json()).decks;
    const guestSize = guestDecks.find((d) => d.id === guestTier).size;
    const firstTier = guestDecks.find((d) => d.kind === 'mistakes' && d.size > 0).id;
    must(guestTier === firstTier, `her worst tier with mistakes is open: ${guestTier} (${guestSize})`);
    const squares = await alice.locator('#hub-grid rect').count();
    must(squares === guestSize, `a square a mistake (${squares})`);
    await alice.click('#hub-go');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    log('TRAIN started the run');
    await runToEnd(alice, guestSize);
    await alice.waitForSelector('#pz-signin-ask');
    must(await alice.locator('#signin-email').count(), 'a guest is asked to sign in, in the one component');
    must(!(await alice.locator('#pz-keep-going').count()), 'and not offered a quota to keep going with');

    const email = `hub-${Date.now()}@oskol.test`;
    await alice.fill('#signin-email', email);
    await alice.click('#signin-send');
    await alice.waitForSelector('#signin-code');
    const mail = await mailFor(alice.request, email);
    await alice.fill('#signin-code', mail.code);
    await alice.waitForSelector('#signin-win');
    await alice.click('#signin-continue');
    await alice.waitForURL(/\/puzzles$/);
    await alice.waitForSelector('#puzzles-hub');
    log('CONTINUE landed back on the practice home');
    // Signed in now, and the page knows it from the server's answer: the
    // browser's zone goes to the deck, once for this load of the page.
    await alice.waitForFunction(() => document.querySelector('#hub-go, #hub-try-one'));
    await sleep(300);
    must(posts.length === 1 && typeof posts[0].tz === 'string' && posts[0].tz.length > 0, `the browser's timezone was sent: ${JSON.stringify(posts[0])}`);

    // The deck fills itself off the request (a job on the review queue);
    // wait for it, and run the sweep by hand if the queue is busy.
    const deckCount = async () => {
      const res = await alice.request.get(`${BASE}/papi/practice`);
      const body = await res.json();
      return (body.counts && body.counts.deck) || 0;
    };
    let deck = 0;
    for (let i = 0; i < 30 && deck === 0; i++) {
      deck = await deckCount();
      if (deck === 0) await sleep(500);
    }
    if (deck === 0) {
      log('the queue has not synced the deck yet: running mix oskol.puzzles.sync --write');
      execFileSync('mix', ['oskol.puzzles.sync', '--write'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      deck = await deckCount();
    }
    must(deck === KEPT, `the account's deck holds her mistakes (${deck})`);

    // ---- 3. as an account ----
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-go[data-action="fix-one"]');
    // One deck open: the worst tier, by the mark the replay draws, a
    // square a mistake, today's ring and one button.
    const decks = (await (await alice.request.get(`${BASE}/papi/practice/decks`)).json());
    const tier = await alice.getAttribute('#hub-card', 'data-deck');
    must(tier === decks.lead && ['very_bad', 'bad', 'doubtful'].includes(tier), `the server's lead is open: ${tier}`);
    const mark = { very_bad: '??', bad: '?', doubtful: '?!' }[tier];
    const front = decks.decks.find((d) => d.id === tier);
    must((await alice.textContent('#hub-card .dk-mark')).trim() === mark, `named by its mark: ${mark}`);
    const grid = await alice.locator('#hub-grid rect').count();
    must(grid === front.size, `the grid is a square a mistake (${grid} of ${front.size})`);
    const ring = await alice.getAttribute('#hub-today svg', 'data-target');
    must(Number(ring) === front.standing.target_today, `today's ring is today's set (${ring})`);
    const fix = (await alice.textContent('#hub-go')).trim();
    must(fix === 'TRAIN', `one button, and it says what it is: "${fix}"`);
    // The other decks are rows, and the open one is not also a row: its
    // card is in its own slot, in the catalog's order.
    const rows = await alice.locator('#hub-rows .dk-row').count();
    must(rows === decks.decks.length - 1, `every other deck is a row (${rows} of ${decks.decks.length - 1})`);
    must(!(await alice.locator(`#hub-row-${tier}`).count()), 'and the open deck is not also a row');
    must(await alice.locator(`#hub-slot-${tier} #hub-card`).count(), 'the open card sits in its own slot');
    // The drawers: tap every closed row in turn, top to bottom. The five
    // slots never change order, and the top of every slot above the one
    // tapped never moves; the card is always in the tapped one's slot.
    const order = decks.decks.map((d) => d.id);
    const slots = () => alice.evaluate(() => [...document.querySelectorAll('#hub-rows > .dk-slot')].map((el) => ({
      id: el.dataset.deck,
      top: el.getBoundingClientRect().top + window.scrollY,
    })));
    const settled = () => alice.evaluate(() => Promise.all(
      [...document.querySelectorAll('.dk-drawer')].flatMap((el) => el.getAnimations()).map((a) => a.finished)));
    const heightOf = () => alice.evaluate(() => document.querySelector('#puzzles-hub').getBoundingClientRect().height);
    await settled();
    const heightBefore = await heightOf();
    // How many closed rows there are to tap depends on the data: on CI the
    // sets are not built and the account's mistakes sit in one tier, so
    // there may be none. Every one there is gets tapped.
    const tappable = await alice.locator('#hub-rows button.dk-row').count();
    let tapped = 0;
    for (const id of order) {
      const row = alice.locator(`#hub-row-${id}`);
      if (!(await row.count()) || (await row.evaluate((el) => el.tagName)) !== 'BUTTON') continue;
      must((await row.getAttribute('aria-expanded')) === 'false', `${id}'s row says it is closed`);
      const before = await slots();
      must(JSON.stringify(before.map((s) => s.id)) === JSON.stringify(order), `the slots are in the decks' order: ${before.map((s) => s.id)}`);
      await row.click();
      await alice.waitForSelector(`#hub-slot-${id} #hub-card[data-deck="${id}"]`);
      await settled();
      const after = await slots();
      must(JSON.stringify(after.map((s) => s.id)) === JSON.stringify(order), `opening ${id} reordered nothing: ${after.map((s) => s.id)}`);
      const at = order.indexOf(id);
      for (let i = 0; i < at; i++) {
        must(Math.abs(after[i].top - before[i].top) < 0.5, `opening ${id} left ${order[i]} above it where it was (${before[i].top} -> ${after[i].top})`);
      }
      tapped++;
    }
    must(tapped === tappable, `every closed drawer was tapped open in turn (${tapped} of ${tappable})`);
    log(tapped > 0
      ? `opened ${tapped} drawers in turn: nothing reordered, nothing above moved`
      : 'no other deck has anything to open here (no sets built, one tier): the drawers were not tapped');
    // And back to the lead: the page is the height it was.
    if (tapped > 0) {
      await alice.click(`#hub-row-${tier}`);
      await alice.waitForSelector(`#hub-slot-${tier} #hub-card[data-deck="${tier}"]`);
      await settled();
      const heightAfter = await heightOf();
      must(heightBefore === heightAfter, `the page is ${heightAfter}px before the drawers were opened and after ${tier} was again`);
    }
    await sleep(300);
    must(posts.length === 2, `the timezone goes once per load of the page, never per fetch (${posts.length} for 2 loads)`);

    // ---- 3b. one mistake is a whole session ----
    // TRAIN, answer one, stop. That has to read as finished.
    await alice.click('#hub-go');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    await alice.waitForSelector('#pz-board .bg-stack');
    await answer(alice);
    await alice.waitForSelector('#pz-reveal');
    must(await alice.locator('#pz-done').count(), "every reveal in a run offers I'M DONE");
    await alice.click('#pz-done');
    await alice.waitForSelector('#pz-end');
    const oneScore = (await alice.textContent('#pz-score')).trim();
    must(/^One /.test(oneScore), `stopping after one reads as a whole session: "${oneScore}"`);
    must(!/ of /.test(oneScore), 'and never as a fraction of a run nobody promised');
    must(await alice.locator('#pz-home').count(), 'the summary offers the way back');
    // Stopped with some of today left: the way on goes on with it.
    await alice.waitForSelector('#pz-keep-going[data-action="continue"]');
    log('I\'M DONE with today unfinished offers KEEP GOING, which goes on with it');
    const oneToday = (await alice.textContent('#pz-today')).trim();
    must(oneToday === '1 practiced today', `the day counts the one: "${oneToday}"`);

    // ---- 3c. the rest of the day's new ones, watching the strip ----
    // The answer that finishes today's set puts the celebration under its
    // reveal: the ring over the board full, "Today's 3 done.", the grid,
    // and KEEP GOING beside I'M DONE -- and nothing above it moves.
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-go[data-action="fix-one"]');
    await alice.click('#hub-go');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    const rest = NEW_PER_DAY - 1;
    let today = null;
    let atReveal = null;
    for (let n = 1; n <= rest; n++) {
      await alice.waitForSelector('#pz-reveal', { state: 'detached' });
      await alice.waitForSelector('#pz-board .bg-stack');
      const before = await progressOf(alice, n);
      must(before.label === mark, `puzzle ${n}: the strip names the tier: "${before.label}"`);
      if (today !== null) must(before.today === today, `the day's count carried over to puzzle ${n} (${before.today})`);
      await answer(alice);
      await alice.waitForSelector('#pz-reveal');
      if (n === rest) atReveal = await layoutOf(alice);
      const after = await progressOf(alice, n);
      must(after.today === before.today + 1, `puzzle ${n}: the day's count moved ${before.today} -> ${after.today}`);
      must(after.ring.done === before.ring.done + 1, `puzzle ${n}: and the ring with it (${after.ring.done}/${after.ring.target})`);
      today = after.today;
      if (n < rest) {
        must(!(await alice.locator('#pz-today-done').count()), `puzzle ${n}: today's set is not done yet, and there is no card`);
        await pressNext(alice);
      }
    }
    must(await alice.locator('#pz-today-done').count(), "the answer that finishes today's set brings the card");
    await alice.waitForSelector('#pz-today-done[data-settled="true"]', { timeout: 15000 });
    must(await alice.isVisible('#pz-today-done'), 'and it is on the screen once it has played');
    const ringDone = await progressOf(alice, rest);
    must(ringDone.ring.done === NEW_PER_DAY && ringDone.ring.target === NEW_PER_DAY && await alice.locator('#pz-ring.is-done').count(),
      `the ring over the board reads a check (${ringDone.ring.done}/${ringDone.ring.target})`);
    must(ringDone.filled === rest, `a tile for each answer of the run in the strip (${ringDone.filled})`);
    must((await alice.textContent('#pz-today-title')).trim() === `Today's ${NEW_PER_DAY} done.`, `the card says so: "${(await alice.textContent('#pz-today-title')).trim()}"`);
    must(Number(await alice.getAttribute('#pz-today-grid svg', 'data-count')) > 0, 'with the tier\'s grid');
    const settledLayout = await layoutOf(alice);
    for (const key of Object.keys(atReveal)) {
      must(JSON.stringify(atReveal[key]) === JSON.stringify(settledLayout[key]),
        `nothing above the card moved: ${key} ${JSON.stringify(settledLayout[key])}`);
    }
    await alice.waitForSelector('#pz-today-way[data-way="keep-going"], #pz-today-way[data-way="practice-anyway"]');
    const way = await alice.getAttribute('#pz-today-way', 'data-way');
    must(await alice.isVisible('#pz-done'), `I'M DONE beside ${way}`);
    must(!(await alice.locator('#pz-next').count()), 'the band under the board leaves the way on to the card');
    // At every size: the card, there or not, moves nothing above it.
    for (const size of [{ width: 390, height: 844 }, { width: 320, height: 568 }, { width: 844, height: 390 }, { width: 1440, height: 900 }]) {
      await alice.setViewportSize(size);
      await sleep(250);
      const shown = await layoutOf(alice);
      await alice.evaluate(() => { document.querySelector('#pz-today-done').style.display = 'none'; });
      await sleep(50);
      const without = await layoutOf(alice);
      await alice.evaluate(() => { document.querySelector('#pz-today-done').style.display = ''; });
      for (const key of Object.keys(shown)) {
        must(JSON.stringify(shown[key]) === JSON.stringify(without[key]),
          `${size.width}x${size.height}: ${key} is where it is without the card (${JSON.stringify(shown[key])} vs ${JSON.stringify(without[key])})`);
      }
      await noSideways(alice, `the card at ${size.width}x${size.height}`);
    }
    await alice.setViewportSize({ width: 390, height: 844 });
    await sleep(200);
    // Read back from the server, so the count is not the client's own
    // arithmetic being asked about itself -- and there is no target.
    const day = (await (await alice.request.get(`${BASE}/papi/practice`)).json()).today;
    must(day && day.done === NEW_PER_DAY && day.target === undefined,
      `the day is a plain count on the wire: ${JSON.stringify(day)}`);
    must(!(await alice.locator('#signin-email').count()), 'an account is not asked to sign in');

    // ---- 3c'. KEEP GOING: more of the pace, the ring grows by them, and
    // the run goes on to its end with no second card ----
    if (way === 'keep-going') {
      await alice.click('#pz-keep-going');
      await alice.waitForSelector('#pz-reveal', { state: 'detached' });
      await alice.waitForSelector('#pz-board .bg-stack');
      const grown = await progressOf(alice, rest + 1);
      must(grown.ring.done === NEW_PER_DAY && grown.ring.target > NEW_PER_DAY && grown.ring.target <= 2 * NEW_PER_DAY,
        `KEEP GOING went on, and the ring reads ${grown.ring.done}/${grown.ring.target}`);
      let cards = 0;
      const more = await playRun(alice, { onReveal: async (page) => { cards += await page.locator('#pz-today-done').count(); } });
      must(more === grown.ring.target - NEW_PER_DAY, `ANOTHER took the run through the ${more} it started, then it ended`);
      must(cards === 0, 'and the card is never drawn twice in a run');
      await alice.waitForSelector('#pz-way[data-way]:not([data-way=""])');
      const endToday = (await alice.textContent('#pz-today')).trim();
      must(endToday === `${NEW_PER_DAY + more} practiced today`, `the day's count, under the score: "${endToday}"`);
    } else {
      await alice.click('#pz-done');
      await alice.waitForSelector('#pz-end');
    }

    // ---- 3d. today's set done: the ring is full, and still a button ----
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-card');
    const done = await alice.getAttribute('#hub-card', 'data-action');
    must(['keep-going', 'practice-anyway'].includes(done), `today's set done, the one button goes on: ${done}`);
    const doneRing = await alice.locator('#hub-today svg');
    must(Number(await doneRing.getAttribute('data-done')) >= Number(await doneRing.getAttribute('data-target')),
      'and the ring is full');
    const quiet = (await alice.textContent('#hub-quiet')).trim();
    must(done === 'keep-going' ? /^Today's \d+ done\. Keep going adds \d+ more\.$/.test(quiet) || /^Nothing due here today/.test(quiet)
      : /scheduled/.test(quiet), `the line under it says why: "${quiet}"`);
    await alice.click('#hub-go');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    await alice.waitForSelector('#pz-board .bg-stack');
    log(`${done} started a run`);

    // ---- 3e. a deck's own page: OPEN from the hub, its button, a run ----
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-open');
    const lead = await alice.getAttribute('#hub-card', 'data-deck');
    const hubAction = await alice.getAttribute('#hub-card', 'data-action');
    const headBefore = await alice.evaluate(() => document.querySelector('#hub-card .dk-head').getBoundingClientRect().height);
    must(headBefore > 0, `the hub's card carries OPEN for ${lead}`);
    await alice.click('#hub-open');
    await alice.waitForURL(/\/practice\/[a-z-]+$/);
    await alice.waitForSelector('#practice-card');
    const slug = new URL(alice.url()).pathname.split('/').pop();
    must(slug === (lead === 'doubtful' ? 'dubious' : lead.replace(/_/g, '-')), `OPEN goes to that deck's page: /practice/${slug}`);
    must(await alice.getAttribute('#practice-card', 'data-deck') === lead, 'and the page is that deck');
    const pageSquares = Number(await alice.getAttribute('#practice-grid svg', 'data-count'));
    must(pageSquares > 0, `a square per position on the page (${pageSquares})`);
    must(await alice.locator('#practice-legend').count() && await alice.locator('#practice-month').count(),
      'the legend under the grid, and the month under the card');
    const pageAction = await alice.getAttribute('#practice-card', 'data-action');
    must(pageAction === hubAction, `the page's button is the hub's, in the same state: ${pageAction}`);
    await alice.click('#practice-go');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    await alice.waitForSelector('#pz-board .bg-stack');
    await answer(alice);
    await alice.waitForSelector('#pz-reveal');
    await alice.click('#pz-done');
    await alice.waitForSelector('#pz-end');
    log(`a run from /practice/${slug} played one and ended`);
    // Back on the page, cold: it is served by the server too.
    await alice.goto(`${BASE}/practice/${slug}`);
    await alice.waitForSelector('#practice-card');
    must((await alice.title()).startsWith(await alice.textContent('#practice-name')), `a cold load names the deck: "${await alice.title()}"`);

    // A stranger on a set's page, cold: TRY walks it. The sets exist only
    // where the operator built them (review-decks builds its own); a set
    // with nothing built is a 404, which is its own assertion.
    const openings = await stranger.goto(`${BASE}/practice/openings`);
    if (openings.status() === 404) {
      log('the openings are not built in this database: their page is a 404, as it should be');
    } else {
      await stranger.waitForSelector('#practice-go[data-action="try"]');
      must(await stranger.locator('#practice-signin-open').count(), 'a stranger on a set is offered the sign-in');
      await stranger.click('#practice-go');
      await stranger.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
      log('TRY from the openings page started a walk');
    }
    // A stranger on a tier: one line and the way back.
    await stranger.goto(`${BASE}/practice/very-bad`);
    await stranger.waitForSelector('#practice-empty-line');
    must(await stranger.getAttribute('#practice-way-back', 'href') === '/puzzles', 'a stranger on a tier gets the way back');

    // ---- 4. phones ----
    for (const size of [{ w: 390, h: 844 }, { w: 320, h: 568 }, { w: 844, h: 390 }]) {
      const what = `${size.w}x${size.h}`;
      await stranger.setViewportSize({ width: size.w, height: size.h });
      await stranger.goto(`${BASE}/puzzles`);
      await stranger.waitForSelector('#hub-try-one');
      await sleep(150);
      await noSideways(stranger, what);
      await alice.setViewportSize({ width: size.w, height: size.h });
      await alice.goto(`${BASE}/puzzles`);
      await alice.waitForSelector('#hub-card');
      await sleep(150);
      await noSideways(alice, `${what} (account)`);
    }

    // ---- 5. more due than a page of a session holds ----
    log(`many due: ${resultLine(execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzles-hub/many_due.exs")'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, SHAPE_EMAIL: email, DUE_COUNT: '25' },
    }))}`);
    await alice.setViewportSize({ width: 390, height: 844 });
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-card[data-deck="very_bad"] #hub-go[data-action="fix-one"]');
    await alice.click('#hub-go');
    await alice.waitForURL(/\/puzzles\/[^/]+$/);
    // The strip measured at three sizes: a stretch of the run at each,
    // every puzzle's strip and board the box the stretch's first had.
    const stretches = [
      { to: 8, width: 390, height: 844 },
      { to: 15, width: 320, height: 568 },
      { to: 22, width: 844, height: 390 },
    ];
    let firstStrip = null;
    let firstBoard = null;
    let stretch = null;
    for (let n = 1; n <= 22; n++) {
      const size = stretches.find((s) => n <= s.to);
      if (size !== stretch) {
        stretch = size;
        await alice.setViewportSize({ width: size.width, height: size.height });
        firstStrip = null;
      }
      await alice.waitForSelector('#pz-reveal', { state: 'detached' });
      await alice.waitForSelector('#pz-board .bg-stack');
      await sleep(150);
      const before = await progressOf(alice, n);
      const boardBefore = await boxOf(alice, '#pz-board');
      await answer(alice);
      await alice.waitForSelector('#pz-reveal');
      await sleep(250);
      const after = await progressOf(alice, n);
      const boardAfter = await boxOf(alice, '#pz-board');
      if (!firstStrip) { firstStrip = before.strip; firstBoard = boardBefore; }
      const at = `${size.width}x${size.height}`;
      must(JSON.stringify(before.strip) === JSON.stringify(firstStrip) && JSON.stringify(after.strip) === JSON.stringify(firstStrip),
        `puzzle ${n} at ${at}: the strip is the box it was at this size's first (${JSON.stringify(after.strip)})`);
      must(boardBefore.y === firstBoard.y && boardAfter.y === firstBoard.y, `puzzle ${n} at ${at}: the board has not moved (y ${boardAfter.y})`);
      const tileRows = await alice.evaluate(() => new Set([...document.querySelectorAll('#pz-marks .pz-tile')].map((t) => Math.round(t.getBoundingClientRect().y))).size);
      must(tileRows === 1, `puzzle ${n} at ${at}: ${n} tiles are one row`);
      if (n < 22) await pressNext(alice);
    }
    must(!(await alice.locator('#pz-end').count()), 'the run went on past the twentieth');

    // On a desktop the strip's height comes off the board, so ANOTHER is on
    // the screen under it.
    for (const size of [{ width: 1440, height: 900 }, { width: 1280, height: 720 }]) {
      await alice.setViewportSize(size);
      await sleep(300);
      const next = await boxOf(alice, '#pz-next');
      must(next.y + next.h <= size.height, `${size.width}x${size.height}: ANOTHER is on screen (bottom ${next.y + next.h} <= ${size.height})`);
    }
    await alice.setViewportSize({ width: 390, height: 844 });

    // ---- 5b. past 25 into PRACTICE ANYWAY ----
    // Nothing new left anywhere, then the rest of the due ones: the run ends
    // on PRACTICE ANYWAY, whose first page of the rotation is twenty of the
    // ones just answered. It must ask past them, not stop.
    log(`start all: ${resultLine(execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzles-hub/many_due.exs")'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, SHAPE_EMAIL: email, DUE_MODE: 'start_all' },
    }))}`);
    await pressNext(alice);
    const tail = await playRun(alice);
    log(`the run went through ${tail} more and ended`);
    await alice.waitForSelector('#pz-anyway');
    await alice.click('#pz-anyway');
    // The end card stays until the next puzzle opens, or says why not.
    await alice.waitForFunction(() => !document.querySelector('#pz-end') || /every one/.test(document.querySelector('#pz-way-line').textContent), null, { timeout: 15000 });
    must(!(await alice.locator('#pz-end').count()), 'PRACTICE ANYWAY after 25 asked past the ones just answered and went on');
    await alice.waitForSelector('#pz-board .bg-stack');
    must((await alice.textContent('#pz-progress-count')).trim() === 'Practice only', 'and the run is practice only');
  } finally {
    for (const c of contexts) await c.close().catch(() => {});
  }
}

(async () => {
  const setup = arrange();
  log(`room ${setup.game_id}: ${setup.puzzles} puzzles`);
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  try {
    await run(browser, setup, errors);
  } finally {
    await browser.close();
  }
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
  }
  log('puzzles hub smoke: all good');
})().catch((e) => { console.error(e); process.exit(1); });
