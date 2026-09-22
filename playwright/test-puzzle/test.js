/**
 * The puzzle page, end to end. `setup.exs` arranges a finished game graded
 * against a stubbed engine, so the puzzles are real positions from a real
 * room. Then:
 *
 *  1. A stranger (a fresh browser) opens a puzzle from its link: the head
 *     carries the question, the page asks it over the board, nothing but
 *     the question is fetched before PLAY and the answer is in none of it.
 *     They stage the roll (UNDO takes a step back), press PLAY, and see the
 *     verdict, their move marked among the candidates, a candidate on the
 *     board and back; SHARE copies the clean link. No level line, no
 *     memory line. A link to no puzzle is the page's own 404.
 *  2. The opponent's browser (the guest holding the other seat) sees the
 *     memory line from their side: "Alice played ... and you won".
 *  3. The player who made the mistake signs in (the mail read from
 *     /dev/last-login), which brings the game and its mistakes into the
 *     account's deck; on the puzzle the reveal ends with the level line and
 *     the four buttons, one preselected, and the memory line "You played
 *     ..."; SOONER puts it back to the start: "back tomorrow".
 *  4. Share with my mistake: only that player's page offers it (not the
 *     stranger's, not the opponent's, and the opponent's POST is a 403).
 *     Pressed, it copies a `?s=` link whose head says "Alice got this
 *     wrong. What's your play?" and whose canonical is the clean page. A
 *     friend in a fresh browser opens it, tries, and reads "Alice played
 *     ... and lost N points"; Bob's name is nowhere on that page, and the
 *     clean link (step 1) told no story.
 *  5. Phones: 390x844, 320x568 and 844x390: nothing scrolls sideways, the
 *     board fits, and upright it is the table's own size.
 *
 * Run with the dev server up (/dev routes on):
 *   node playwright/test-puzzle/test.js
 */
const playwright = require('playwright');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');

const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrange() {
  if (process.env.PUZZLE_JSON) return JSON.parse(process.env.PUZZLE_JSON);
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(resultLine(out));
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

/** Stage the whole roll: a tap on a source point plays it with the next
 * die, as at the table, until PLAY is offered. */
async function stageATurn(page) {
  for (let i = 0; i < 6; i++) {
    if (await page.locator('#bg-action-play').count()) return;
    const source = page.locator('.bg-point.source, .bg-bar.source');
    must((await source.count()) > 0, 'the board offers a checker to move');
    await source.first().click();
    await sleep(150);
  }
  must(await page.locator('#bg-action-play').count(), 'PLAY is offered once the roll is played');
}

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

async function boardFits(page, what) {
  const b = await page.locator('#pz-board .bg-stack').boundingBox();
  const vp = page.viewportSize();
  must(b.x >= 0 && b.x + b.width <= vp.width + 1, `${what}: the board is within the screen's width`);
  must(b.y >= -1 && b.y + b.height <= vp.height + 1, `${what}: the board is within the screen's height`);
  return b;
}

function watchRequests(page, seen) {
  page.on('request', (r) => {
    const url = r.url();
    if (url.includes('/papi/')) seen.push({ method: r.method(), path: url.replace(BASE, '') });
  });
}

async function run(browser, setup, errors) {
  const puzzle = setup.players[0].puzzle;
  must(puzzle && puzzle.id, 'the graded game has a checker-play mistake of the first seat');
  const url = `${BASE}/puzzles/${puzzle.id}`;
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
    // ---- 1. a stranger, from the link ----
    const strangerContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await strangerContext.grantPermissions(['clipboard-read', 'clipboard-write']);
    const stranger = await open('stranger', strangerContext);
    const requests = [];
    watchRequests(stranger, requests);
    const bodies = [];
    stranger.on('response', async (r) => {
      if (r.url().includes(`/papi/puzzles/${puzzle.id}`) && r.request().method() === 'GET') bodies.push(await r.text());
    });

    await stranger.goto(url);
    const html = await stranger.content();
    must(/property="og:title"[^>]*content="White to play/.test(html), 'the head carries the question as og:title');
    must(!html.includes('name="robots"'), 'a puzzle is indexable');
    must(!html.includes('Alice') && !html.includes('Bob'), 'the head names nobody');
    await stranger.waitForSelector('#pz-board .bg-stack');
    const prompt = (await stranger.textContent('#pz-prompt')).trim();
    must(/^White to play \d-\d\. What's your play\?$/.test(prompt), `the page asks the question: "${prompt}"`);
    must((await stranger.title()).startsWith(prompt), 'the document title is the question');

    // Before PLAY: only the question was fetched, and the answer is in none of it.
    await sleep(300);
    const before = requests.filter((r) => r.path.includes('/puzzles/'));
    must(before.every((r) => r.method === 'GET' && !/attempts|mine/.test(r.path)), `nothing but the question is fetched before PLAY (${before.map((r) => r.path).join(', ')})`);
    must(bodies.length === 1 && !/verdict|equity|"best"|notation/.test(bodies[0]), 'the question carries no answer');

    // UNDO takes the step back.
    const sources = await stranger.locator('.bg-point.source, .bg-bar.source').count();
    must(sources > 0, 'the board offers the legal moves');
    await stranger.locator('.bg-point.source, .bg-bar.source').first().click();
    await stranger.waitForSelector('#bg-action-undo');
    await stranger.click('#bg-action-undo');
    await sleep(150);
    must(!(await stranger.locator('#bg-action-undo').count()), 'UNDO takes the staged move back');
    must((await stranger.locator('.bg-point.source, .bg-bar.source').count()) === sources, 'and the same moves are offered again');

    await stageATurn(stranger);
    await stranger.click('#bg-action-play');
    await stranger.waitForSelector('#pz-reveal');
    const verdict = await stranger.getAttribute('#pz-verdict', 'data-verdict');
    must(['pass', 'hold', 'fail'].includes(verdict), `the verdict is in: ${verdict}`);
    must((await stranger.locator('#pz-candidates .rp-cand').count()) >= 2, 'the candidate table is there');
    must((await stranger.locator('#pz-candidates .rp-cand[data-yours="true"]').count()) === 1, 'your move is marked among the candidates');
    must(!(await stranger.locator('#bg-action-play').count()), 'the board is a picture once the answer is in');
    must(!(await stranger.locator('#pz-level').count()), 'a guest has no level line');
    must(!(await stranger.locator('#pz-memory').count()), 'a stranger has no memory line');
    must(!(await stranger.locator('#pz-story').count()), 'the clean link tells no story');
    must(!(await stranger.locator('#pz-share-story').count()), 'a stranger cannot share a mistake');
    must(!(await stranger.locator('#pz-next').count()), 'a puzzle opened from a link has no NEXT');
    const attempts = requests.filter((r) => r.path.endsWith('/attempts'));
    must(attempts.length === 1 && attempts[0].method === 'POST', 'one attempt was posted');

    // A candidate on the board, and back.
    const other = stranger.locator('#pz-candidates .rp-cand:not([data-yours="true"])').first();
    await other.click();
    await stranger.waitForSelector('#pz-board.is-proposed');
    must(true, 'a candidate goes on the board');
    await stranger.locator('#pz-candidates .rp-cand[data-yours="true"]').click();
    await sleep(100);
    must(!(await stranger.locator('#pz-board.is-proposed').count()), 'and your move comes back');

    // SHARE copies the clean link.
    await stranger.click('#pz-share');
    await stranger.waitForFunction(() => document.querySelector('#pz-share').textContent.trim() === 'Copied', null, { timeout: 3000 });
    const copied = await stranger.evaluate(() => navigator.clipboard.readText());
    must(copied === url, `SHARE copied the clean link: ${copied}`);

    // The page's own 404, reached without a page load.
    await stranger.evaluate(() => {
      history.pushState({}, '', '/puzzles/nope0000');
      dispatchEvent(new PopStateEvent('popstate'));
    });
    await stranger.waitForSelector('#pz-missing');
    must(true, 'a link to no puzzle is the page\'s own 404');
    const cold = await stranger.request.get(`${BASE}/puzzles/nope0000`);
    must(cold.status() === 404, 'and a cold load of it is a 404');

    // ---- 2. the opponent, still a guest ----
    const bob = await open('bob', await seatedContext(browser, setup.players[1].guest, { viewport: { width: 390, height: 844 } }));
    await bob.goto(url);
    await bob.waitForSelector('#pz-board .bg-stack');
    await stageATurn(bob);
    await bob.click('#bg-action-play');
    await bob.waitForSelector('#pz-memory');
    const bobLine = (await bob.textContent('#pz-memory')).trim();
    must(/^From your game vs Alice, \d+ \w{3}\. Alice played .+ \(a (dubious|bad|very bad) move\) and you (won|lost) \d+ points?\./.test(bobLine), `the opponent's memory line: "${bobLine}"`);
    const bobLink = await bob.getAttribute('#pz-memory-link', 'href');
    must(bobLink.startsWith(`/backgammon/${setup.game_id}/replay?game=1&step=`), `it links to the moment in the replay: ${bobLink}`);
    must(!(await bob.locator('#pz-level').count()), 'a guest, seated or not, has no level line');
    must(!(await bob.locator('#pz-share-story').count()), 'the opponent is not offered "Share with my mistake"');
    const bobMint = await bob.evaluate(async (id) => {
      const csrf = document.querySelector('meta[name="csrf-token"]').content;
      const res = await fetch(`/papi/puzzles/${id}/shares`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': csrf }, body: '{}' });
      return { status: res.status, body: await res.json() };
    }, puzzle.id);
    must(bobMint.status === 403 && bobMint.body.error.code === 'forbidden', `and the server refuses the opponent's POST: ${bobMint.status} ${bobMint.body.error.message}`);

    // ---- 3. the player who made the mistake, signed in ----
    const aliceContext = await seatedContext(browser, setup.players[0].guest, { viewport: { width: 390, height: 844 } });
    const alice = await open('alice', aliceContext);
    const email = `puzzle-${Date.now()}@oskol.test`;
    await alice.goto(`${BASE}/`);
    await alice.waitForSelector('#account-button');
    // The resume dialog (LIVE GAMES) may be up over the board: it lists no
    // finished game, so the account menu is the way in.
    if (await alice.locator('#resume-modal').count()) await alice.keyboard.press('Escape');
    await alice.click('#account-button');
    await alice.click('#signin-menu');
    await alice.waitForSelector('#signin-email');
    await alice.fill('#signin-email', email);
    await alice.click('#signin-send');
    await alice.waitForSelector('#signin-code');
    const mail = await mailFor(alice.request, email);
    await alice.fill('#signin-code', mail.code);
    await alice.waitForSelector('#signin-win');
    const saved = (await alice.textContent('#signin-saved')).trim();
    must(saved.startsWith('1 game saved'), `the finished game came with the account: "${saved}"`);
    await alice.click('#signin-continue');

    // The deck fills itself, off the request: the sign-in casts a deck job
    // to the server's review queue. Wait for the card -- and when the queue
    // is busy with other rooms' reviews (under bin/check the earlier
    // smokes leave it a backlog against no engine, one room at a time), run
    // the sweep by hand, which is the operator's lever for exactly that.
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
    must(deck > 0, `the account's deck holds its mistakes (${deck})`);

    await alice.goto(url);
    await alice.waitForSelector('#pz-board .bg-stack');
    await stageATurn(alice);
    await alice.click('#bg-action-play');
    await alice.waitForSelector('#pz-level');
    const line = (await alice.textContent('#pz-level-line')).trim();
    must(/^Level \d+( → \d+)? · back (tomorrow|in \d+ days)$/.test(line), `the level line: "${line}"`);
    must((await alice.locator('#pz-outcomes button').count()) === 4, 'the four buttons are offered');
    must((await alice.locator('#pz-outcomes button[aria-pressed="true"]').count()) === 1, 'the graded one is preselected');
    const aliceLine = (await alice.textContent('#pz-memory')).trim();
    // The opponent by name; the account is Alice's own (its name is never
    // sent back to her), so the line names Bob.
    must(/^From your game vs Bob, \d+ \w{3}\. You played .+ \(a (dubious|bad|very bad) move\) and (won|lost) \d+ points?\./.test(aliceLine), `the player's memory line: "${aliceLine}"`);

    await alice.click('#pz-outcome-sooner');
    await alice.waitForFunction(() => document.querySelector('#pz-outcome-sooner').getAttribute('aria-pressed') === 'true', null, { timeout: 5000 });
    const sooner = (await alice.textContent('#pz-level-line')).trim();
    must(/^Level \d+ → 0 · back tomorrow$/.test(sooner) || /^Level 0 · back tomorrow$/.test(sooner), `SOONER puts it back to the start: "${sooner}"`);

    // ---- 4. share with my mistake ----
    await aliceContext.grantPermissions(['clipboard-read', 'clipboard-write']);
    must((await alice.locator('#pz-share-story').count()) === 1, 'the player whose mistake it was is offered "Share with my mistake"');
    // Alice signed in, so her seat is the account's and the story names the
    // account by its username, whatever it was called at the door.
    const me = await (await alice.request.get(`${BASE}/papi/me`)).json();
    const sharer = me.user && me.user.name;
    must(sharer && sharer !== 'Bob', `the sharer is the account, shown as "${sharer}"`);
    const mintStarted = new Map();
    alice.on('request', (r) => { if (r.url().endsWith('/shares') && r.method() === 'POST') mintStarted.set(r, Date.now()); });
    alice.on('response', (r) => {
      const started = mintStarted.get(r.request());
      if (started) log(`measured: POST /shares answered ${r.status()} in ${Date.now() - started} ms`);
    });
    await alice.click('#pz-share-story');
    await alice.waitForFunction(() => document.querySelector('#pz-share-story').textContent.trim() === 'Copied', null, { timeout: 5000 });
    const storyUrl = await alice.evaluate(() => navigator.clipboard.readText());
    const storyMatch = storyUrl.match(new RegExp(`^${url.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\?s=([0-9A-HJKMNP-TV-Z]{12})$`));
    must(storyMatch, `it copied a story link: ${storyUrl}`);
    await alice.click('#pz-share-story');
    await alice.waitForFunction(() => document.querySelector('#pz-share-story').textContent.trim() === 'Copied', null, { timeout: 5000 });
    must((await alice.evaluate(() => navigator.clipboard.readText())) === storyUrl, 'and pressing it again copies the same link');

    // The head a chat app reads off the story link.
    const storyHead = await (await alice.request.get(storyUrl)).text();
    must(storyHead.includes(`property="og:title" content="${sharer} got this wrong. What&#39;s your play?"`), `the story link unfurls as "${sharer} got this wrong. What's your play?"`);
    // The canonical's host is the endpoint's own (config, not PORT); its
    // path is what matters: the clean page, no token.
    const canonical = (storyHead.match(/<link[^>]*rel="canonical"[^>]*href="([^"]+)"/) || [])[1] || '';
    must(canonical.endsWith(`/puzzles/${puzzle.id}`), `and its canonical is the clean page: ${canonical}`);
    must(!storyHead.includes('Bob') && !storyHead.includes(puzzle.played), 'the head names no opponent and gives away no move');
    const plainHead = await (await alice.request.get(url)).text();
    must(!plainHead.includes('got this wrong'), 'the clean link\'s head is the plain question');

    // A friend, in a fresh browser.
    const friend = await open('friend', await browser.newContext({ viewport: { width: 390, height: 844 } }));
    await friend.goto(storyUrl);
    await friend.waitForSelector('#pz-board .bg-stack');
    must(!(await friend.locator('#pz-story').count()), 'the friend reads no story before trying');
    must(friend.url() === storyUrl, `the page keeps the token in the address bar: ${friend.url()}`);
    friend.on('response', async (r) => {
      if (r.url().includes('/attempts') && r.request().method() === 'POST') {
        const body = await r.text();
        const story = (JSON.parse(body).story || {});
        log(`measured: the reveal with a story is ${body.length} bytes, the story itself ${JSON.stringify(story).length}`);
      }
    });
    await stageATurn(friend);
    await friend.click('#bg-action-play');
    await friend.waitForSelector('#pz-story');
    const storyLine = (await friend.textContent('#pz-story')).trim();
    must(new RegExp(`^${sharer} played .+ \\(a (dubious|bad|very bad) move\\)( and (lost \\d+ points?|won anyway))?\\.$`).test(storyLine), `the story: "${storyLine}"`);
    must(storyLine.includes(`${sharer} played ${puzzle.played}`), 'and it is the move Alice really played');
    const friendPage = await friend.evaluate(() => document.body.innerText);
    must(!friendPage.includes('Bob'), 'the opponent\'s name is nowhere on the friend\'s page');
    must(!(await friend.locator('#pz-memory').count()) && !(await friend.locator('#pz-share-story').count()), 'the friend has no memory line and nothing to share of their own');

    // ---- 5. phones ----
    const table = await bob.context().newPage();
    await table.goto(`${BASE}/backgammon/${setup.game_id}`);
    await table.waitForSelector('.bg-page .bg-board');
    for (const size of [{ w: 390, h: 844 }, { w: 320, h: 568 }, { w: 844, h: 390 }]) {
      const what = `${size.w}x${size.h}`;
      await stranger.setViewportSize({ width: size.w, height: size.h });
      await stranger.goto(url);
      await stranger.waitForSelector('#pz-board .bg-stack');
      await sleep(200);
      await noSideways(stranger, what);
      const b = await boardFits(stranger, what);
      if (size.w < size.h) {
        await table.setViewportSize({ width: size.w, height: size.h });
        await sleep(200);
        const t = await table.locator('.bg-page .bg-board').boundingBox();
        const p = await stranger.locator('#pz-board .bg-board').boundingBox();
        must(Math.abs(t.width - p.width) <= 2 && Math.abs(t.height - p.height) <= 2,
          `${what}: the board is the table's own size (${Math.round(p.width)}x${Math.round(p.height)} against ${Math.round(t.width)}x${Math.round(t.height)})`);
      } else {
        must(b.height >= size.h * 0.8, `${what}: the board takes the screen's height (${Math.round(b.height)} of ${size.h})`);
      }
    }
  } finally {
    for (const c of contexts) await c.close().catch(() => {});
  }
}

(async () => {
  const setup = arrange();
  log(`room ${setup.game_id}: ${setup.puzzles} puzzles; opening ${setup.players[0].puzzle.id}`);
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
  log('puzzle smoke: all good');
})().catch((e) => { console.error(e); process.exit(1); });
