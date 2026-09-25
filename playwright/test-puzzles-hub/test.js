/**
 * The practice home and a session, end to end. `test-puzzle/setup.exs`
 * arranges a finished game graded against a stubbed engine; Alice's seat
 * is then trimmed to twelve mistakes, so the numbers below are known:
 * a guest's session is all twelve, an account's first is the day's three
 * new (worst first), which is what one tier's FIX ONE run holds.
 *
 *  1. A stranger (a fresh browser) opens /puzzles: what this is, TRY ONE,
 *     and TRY ONE opens a puzzle with no NEXT (one puzzle is not a run).
 *  2. Alice, a guest holding the seat that made the mistakes, opens
 *     /puzzles: "12 mistakes from your 1 game", that nothing is saved,
 *     PRACTICE. The run: twelve puzzles, PLAY and NEXT each, then the
 *     score and the sign-in ask. She signs in right there (the mail read
 *     from /dev/last-login) and CONTINUE lands her back on /puzzles with
 *     a deck: the counts line, and her timezone sent once.
 *  3. As an account: the head names the worst of what she has made and
 *     the card leads with one tier (its mark, what is left to fix, FIX
 *     ONE) and the others are quiet rows; FIX ONE runs that tier -- the
 *     counter and the marks watched over each of them -- and ends on
 *     the summary with the way back. I'M DONE ends a run after one.
 *  4. Phones: the home at 390x844, 320x568 and 844x390 scrolls nowhere
 *     sideways.
 *
 * Run with the dev server up (/dev routes on):
 *   node playwright/test-puzzles-hub/test.js
 */
const playwright = require('playwright');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { pressNext } = require('../lib/puzzles');

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

/** The strip over the board: the tier's mark and the day's count, and a
 * mark for each mistake answered so far -- never one for a mistake that
 * may never be reached, because a run has no length. */
async function progressOf(page, seen) {
  const count = (await page.textContent('#pz-progress-count')).trim();
  const marks = await page.locator('#pz-marks [data-mark]').count();
  must(marks === seen, `a mark for each mistake reached so far (${marks} of ${seen})`);
  return {
    count,
    filled: await page.locator('#pz-marks [data-mark]:not([data-mark="blank"])').count(),
    today: Number((count.match(/(\d+) fixed today/) || [0, 0])[1]),
  };
}

/** A whole run, watching the strip over the first three: the counter
 * advances, this puzzle's mark fills in as its answer lands, and the
 * day's ring moves with it (and only once per card). */
async function runWatchingProgress(page, expected, watch, mark) {
  let today = null;
  for (let n = 1; n <= expected; n++) {
    await page.waitForSelector('#pz-reveal', { state: 'detached' });
    await page.waitForSelector('#pz-board .bg-stack');
    const watching = n <= watch;
    if (watching) {
      const before = await progressOf(page, n);
      must(before.count.startsWith(`${mark} · `), `puzzle ${n}: the counter names the tier: "${before.count}"`);
      must(!/ of /.test(before.count), `puzzle ${n}: and promises no length: "${before.count}"`);
      must(before.filled === n - 1, `puzzle ${n}: ${n - 1} marks filled in before it is answered (${before.filled})`);
      if (today !== null) must(before.today === today, `the day's count carried over to puzzle ${n} (${before.today})`);
      today = before.today;
    }
    await answer(page);
    await page.waitForSelector('#pz-reveal');
    if (watching) {
      const after = await progressOf(page, n);
      must(after.filled === n, `puzzle ${n}: its own mark fills in with the answer (${after.filled})`);
      must(after.today === today + 1, `puzzle ${n}: the day's count moved ${today} -> ${after.today}`);
      today = after.today;
    }
    await pressNext(page);
    log(`puzzle ${n} answered`);
  }
  await page.waitForSelector('#pz-end');
  const score = (await page.textContent('#pz-score')).trim();
  must(new RegExp(`^\\d+ of ${expected} right$`).test(score), `the run ends on its score: "${score}"`);
  return score;
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
    must(!(await stranger.locator('#hub-practice').count()), 'and has nothing to practice');
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
    await alice.waitForSelector('#hub-practice');
    const headline = (await alice.textContent('#hub-headline')).trim();
    must(headline === `${KEPT} mistakes from your 1 game`, `a guest reads what is hers: "${headline}"`);
    must(await alice.locator('#hub-unsaved').count(), 'and that nothing is saved yet');
    must(posts.length === 0, 'a guest\'s timezone is nobody\'s to keep');
    await alice.click('#hub-practice');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    log('PRACTICE started the run');
    await runToEnd(alice, KEPT);
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
    await alice.waitForFunction(() => document.querySelector('#hub-practice, #hub-fix-one, #hub-try-one'));
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
    await alice.waitForSelector('#hub-fix-one');
    // One tier in front, by the mark the replay draws, with the one
    // number that matters and one button.
    const tier = await alice.getAttribute('#hub-tier', 'data-tier');
    must(['very_bad', 'bad', 'doubtful'].includes(tier), `one tier is in front: ${tier}`);
    const mark = { very_bad: '??', bad: '?', doubtful: '?!' }[tier];
    const head = (await alice.textContent('#hub-tier')).trim();
    must(head.includes(mark), `named by its mark: "${head.split('\n')[0]}"`);
    const left = (await alice.textContent('#hub-tier-left')).trim();
    must(/^\d+ left to fix$/.test(left), `and by what is left to fix: "${left}"`);
    const fix = (await alice.textContent('#hub-fix-one')).trim();
    must(fix === 'FIX ONE', `one button, and it asks for one: "${fix}"`);
    const today = (await alice.textContent('#hub-today')).trim();
    must(/fixed( yet)? today$/.test(today), `the day is a count and nothing else: "${today}"`);
    must(!/ of /.test(today), 'with no denominator to fall short of');
    must(!(await alice.locator('#hub-keep-going').count()), 'and no quota to keep going with');
    // The tiers she is not on are quiet rows -- one per band she has
    // made a mistake in, less the one already in front. This room's
    // mistakes may all be of one band, and then there are none.
    const bands = (await (await alice.request.get(`${BASE}/papi/practice`)).json()).severity;
    const others = bands.filter((b) => b.total > 0 && b.grade !== tier).length;
    const rows = await alice.locator('#hub-tier-rows [data-tier]').count();
    must(rows === others, `the tiers she is not on are quiet rows (${rows} of ${others})`);
    must(!(await alice.locator(`#hub-tier-row-${tier}`).count()), 'and the tier in front is not also a row');
    const patchedNote = (await alice.textContent('#hub-patched-note')).trim();
    must(/Patched: right four times running\./.test(patchedNote), 'and what patched means is said once');
    await sleep(300);
    must(posts.length === 2, `the timezone goes once per load of the page, never per fetch (${posts.length} for 2 loads)`);

    // ---- 3b. one mistake is a whole session ----
    // FIX ONE, answer one, stop. That has to read as finished.
    await alice.click('#hub-fix-one');
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
    must(!(await alice.locator('#pz-keep-going').count()), 'and nothing to keep going with');
    const oneToday = (await alice.textContent('#pz-today')).trim();
    must(oneToday === '1 fixed today', `the day counts the one: "${oneToday}"`);

    // ---- 3c. the rest of the day's new ones, watching the strip ----
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-fix-one');
    await alice.click('#hub-fix-one');
    await alice.waitForURL(/\/puzzles\/[0-9A-Z]{8}/i);
    const rest = NEW_PER_DAY - 1;
    await runWatchingProgress(alice, rest, rest, mark);
    await alice.waitForSelector('#pz-end');
    must(!(await alice.locator('#pz-more-due').count()), 'the end card counts nothing that is left');
    const endToday = (await alice.textContent('#pz-today')).trim();
    must(endToday === `${NEW_PER_DAY} fixed today`, `the day's count, under the score: "${endToday}"`);
    // Read back from the server, so the count is not the client's own
    // arithmetic being asked about itself -- and there is no target.
    const day = (await (await alice.request.get(`${BASE}/papi/practice`)).json()).today;
    must(day && day.done === NEW_PER_DAY && day.target === undefined,
      `the day is a plain count on the wire: ${JSON.stringify(day)}`);
    // Nothing is patched by a first answer -- patched is four in a row --
    // so the end card says the score and nothing about fixing anything.
    must(!(await alice.locator('#pz-patched').count()),
      'a first answer patches nothing, and the end card claims nothing');
    must(!(await alice.locator('#signin-email').count()), 'an account is not asked to sign in');

    // ---- 3d. the day's new ones spent: the tier is in good shape ----
    await alice.goto(`${BASE}/puzzles`);
    await alice.waitForSelector('#hub-tier');
    must(await alice.locator('#hub-tier-good').count(), 'a tier with nothing left today says so');
    const goodLine = (await alice.textContent('#hub-tier-good')).trim();
    must(/good shape\.$/.test(goodLine), `warmly, and by its mark: "${goodLine}"`);
    must(!(await alice.locator('#hub-fix-one').count()), 'and offers no run it cannot serve');
    const nextOffer = await alice.locator('#hub-tier-next').count();
    if (nextOffer) {
      const offer = (await alice.textContent('#hub-tier-next')).trim();
      must(/^WORK ON /.test(offer), `the next tier down is the only thing to press: "${offer}"`);
    } else {
      must(!(await alice.locator('#puzzles-hub button').count()),
        'every tier in good shape: one warm line, and nothing to press');
    }

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
      await alice.waitForSelector('#hub-tier');
      await sleep(150);
      await noSideways(alice, `${what} (account)`);
    }
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
