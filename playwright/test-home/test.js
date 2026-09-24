/**
 * The signed-in home at `/`, end to end.
 *
 * `setup.exs` makes an account with two dozen graded games behind it and a
 * browser signed into it (the guest cookie that account is bound to); the
 * live game is a real one, created here and joined from a second browser.
 *
 *  1. That browser opens `/`: the bar names the account, and PLAY, JOIN,
 *     PUZZLES and the board picker are on it. No board.
 *  2. It creates a game -- signed in, the dialog asks for no name -- and a
 *     second browser joins it.
 *  3. Back at `/`: LIVE GAMES lists the room, whose move it is, and one tap
 *     opens it.
 *  4. Form, at the top of the page: Recent and Career, Recent the better
 *     of the two (the fixture's games improve), the streak beside them,
 *     the sentence, and the line drawn over every graded game.
 *  5. Practice: an account that has never practised is told what fills the
 *     deck. (A deck with cards in it is drawn in `assets/tests/HomeTest.elm`
 *     on a real answer; filling one here means extracting puzzles from a
 *     played game, which the puzzle smokes already do.)
 *  6. Recent matches: ten rooms, then MORE brings the rest and goes. The
 *     match to seven is one line that opens to show its nine games, and a
 *     single game's line opens its replay.
 *  7. A guest at `/` still gets the board: the home this page replaces is
 *     only replaced for an account.
 *
 * Screenshots at 390x844, 320x568, 844x390 and 1440x900, and nothing
 * scrolls sideways at any of them.
 *
 * Run with the dev server up:
 *   node playwright/test-home/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execSync } = require('child_process');
const { BASE, createGame, joinByLink, resultLine, seatedContext } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/test-home';
const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

/** The page at every size, then back to where it was. */
async function shots(page, label) {
  const before = page.viewportSize();
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${SHOTS}/${label}-${size.name}.png`, fullPage: true });
    await noSideways(page, `${label} at ${size.width}x${size.height}`);
  }
  await page.setViewportSize(before);
}

/** Nothing on the page is wider than the screen. */
async function noSideways(page, what) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (wide > 1) throw new Error(`${what}: the page scrolls sideways by ${wide}px`);
}

/** `/`, once /papi/me has said which of the two homes this browser gets. */
async function openHome(page) {
  await page.goto(`${BASE}/`);
  await page.waitForSelector('#home-bar');
  await page.waitForSelector('#home-form, #home-failed');
  if (await page.$('#home-failed')) throw new Error('the home failed to load');
}

const number = async (page, selector) =>
  Number(await page.getAttribute(selector, 'data-pr'));

async function run(browser, errors, fixture) {
  const contexts = [];
  const open = async (who, guestId) => {
    const options = { viewport: { width: 390, height: 844 } };
    const context = guestId
      ? await seatedContext(browser, guestId, options)
      : await browser.newContext(options);
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    contexts.push(context);
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
    return { context, page };
  };

  try {
    const a = await open('account', fixture.guest_id);

    // 1. The bar.
    await openHome(a.page);
    const name = (await a.page.textContent('#account-button')).trim();
    if (!name.includes(fixture.username)) throw new Error(`the bar should name the account: "${name}"`);
    if (name.includes('@')) throw new Error(`the bar must never show the email: "${name}"`);
    for (const control of ['#home-play', '#home-join', '#home-puzzles', '#bg-theme-button']) {
      if (!(await a.page.$(control))) throw new Error(`the bar is missing ${control}`);
    }
    if (await a.page.$('.bg-page.home-board')) throw new Error('the signed-in home has no board');
    log(`the bar names ${fixture.username} and offers PLAY, JOIN, PUZZLES and the boards`);

    // 4 (before there is a live game, so the form is what is on screen).
    const recent = await number(a.page, '#home-form-recent [data-pr]');
    const career = await number(a.page, '#home-form-career [data-pr]');
    if (!(recent > 0 && career > 0)) throw new Error(`the form should print two ratings: ${recent}/${career}`);
    if (!(recent < career)) throw new Error(`the fixture improves, so Recent should beat Career: ${recent}/${career}`);
    const sentence = (await a.page.textContent('#home-form-sentence')).trim();
    if (!sentence.includes('better than your career')) throw new Error(`the sentence: "${sentence}"`);
    const drawn = await a.page.getAttribute('#home-form svg[data-games]', 'data-games');
    if (Number(drawn) !== fixture.games) throw new Error(`the line should draw all ${fixture.games} games, not ${drawn}`);
    // The streak: every game of the fixture finished today, so the player
    // has been here at least a day.
    const streak = Number(await a.page.getAttribute('#home-form-streak [data-days]', 'data-days'));
    if (!(streak >= 1)) throw new Error(`the streak should count today: ${streak}`);
    log(`form: recent ${recent}, career ${career}, ${drawn} games on the line, ${streak}-day streak`);

    // 5. Practice, for an account that has never practised.
    const practice = (await a.page.textContent('#home-practice')).trim();
    if (!practice.includes('Your mistakes become puzzles here after your first graded game.')) {
      throw new Error(`the empty deck should say what fills it: "${practice}"`);
    }

    // 6. Recent matches: ten rooms, then MORE.
    const rows = async () => (await a.page.$$('#home-recent-list > li')).length;
    if ((await rows()) !== 10) throw new Error(`the home carries ten rooms, not ${await rows()}`);

    // The match is one line, and it says so: the format, the score and how
    // many games are behind it.
    const matchRow = `#home-room-${fixture.match_id}`;
    const match = (await a.page.textContent(matchRow)).trim();
    if (!match.includes('Match to 7')) throw new Error(`the match line should name the format: "${match}"`);
    if (!match.includes('won 7-4')) throw new Error(`the match line should carry the score: "${match}"`);
    if (!match.includes(`${fixture.match_games} games`)) {
      throw new Error(`the match line should say how many games: "${match}"`);
    }
    await shots(a.page, '01-home');

    // Pressed, it opens in place: its games, each a link to its own replay.
    if (await a.page.$(`#home-room-${fixture.match_id}-games`)) {
      throw new Error('a match should be closed until it is pressed');
    }
    await a.page.click(matchRow);
    await a.page.waitForSelector(`#home-room-${fixture.match_id}-games`);
    const inner = await a.page.$$(`#home-room-${fixture.match_id}-games > li`);
    if (inner.length !== fixture.match_games) {
      throw new Error(`the match should open to ${fixture.match_games} games, not ${inner.length}`);
    }
    if ((await rows()) !== 10) throw new Error('opening a match should not add lines to the list');
    await shots(a.page, '01b-home-match-open');
    log(`recent: the match is one line of ${fixture.match_games} games, and opens in place`);

    // Ten at a time, and MORE goes when the server says there is no more:
    // 24 games is three pages, so it takes more than one press.
    let presses = 0;
    while (await a.page.$('#home-more')) {
      const before = await rows();
      await a.page.click('#home-more');
      await a.page.waitForFunction(
        (n) => document.querySelectorAll('#home-recent-list > li').length > n,
        before
      );
      if (++presses > 5) throw new Error('MORE never ran out');
    }
    if ((await rows()) !== fixture.rooms) {
      throw new Error(`MORE should leave all ${fixture.rooms} rooms, not ${await rows()}`);
    }
    log(`recent: ten rooms, then ${presses} presses of MORE brought the other ${fixture.rooms - 10} and it went`);

    // A tap on a game opens its replay.
    await a.page.click(`a[href="${fixture.newest_replay}"]`);
    await a.page.waitForURL(/\/replay/);
    log(`a game opened its replay at ${a.page.url().replace(BASE, '')}`);

    // 2 and 3. A real live game: created signed in, joined from elsewhere.
    const game = await createGame(a.page, {});
    const b = await open('opponent');
    await joinByLink(b.page, game.inviteUrl, 'Bob');
    await a.page.waitForSelector('.bg-board .checker');

    await openHome(a.page);
    await a.page.waitForSelector(`#home-live-list #resume-${game.gameId}`);
    const live = (await a.page.textContent(`#resume-${game.gameId}`)).trim();
    if (!live.includes('vs Bob')) throw new Error(`the live row should name the opponent: "${live}"`);
    if (!/Your move|Their move/.test(live)) throw new Error(`the live row should say whose move it is: "${live}"`);
    await shots(a.page, '02-home-live');
    await a.page.click(`#resume-${game.gameId}`);
    await a.page.waitForSelector('.bg-board .checker');
    if (a.page.url().includes('?game=')) throw new Error('one tap from LIVE GAMES did not open the seat');
    log('live games: the room, whose move it is, and one tap in');

    // 7. A guest still gets the board.
    const guest = await open('guest');
    await guest.page.goto(`${BASE}/`);
    await guest.page.waitForSelector('#start-game');
    if (await guest.page.$('#home-bar')) throw new Error('a guest was given the account home');
    log('a guest still gets the board; HOME OK');
  } catch (e) {
    for (const context of contexts) {
      await Promise.all(
        context.pages().map((pg, i) =>
          pg.screenshot({ path: `${SHOTS}/99-failure-${contexts.indexOf(context)}-${i}.png` }).catch(() => {})
        )
      );
    }
    throw e;
  } finally {
    for (const context of contexts) await context.close();
  }
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const fixture = JSON.parse(
    resultLine(
      execSync(`mix run -e 'Code.eval_file("playwright/test-home/setup.exs")'`, {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'inherit'],
      })
    )
  );
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  try {
    await run(browser, errors, fixture);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
  } catch (e) {
    console.error('HOME SMOKE FAILED:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
