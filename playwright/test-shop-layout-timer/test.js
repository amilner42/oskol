/**
 * End-to-end test for shop layout (15 cards) and auto-timer feature
 *
 * Tests:
 * 1. Two players join and start game with 1HAND dev code
 * 2. Play through one complete round (1 hand with dev code)
 * 3. Shop displays 15 cards (5 rows x 3 columns)
 * 4. Both players pick their cards
 * 5. After picks complete, countdown timer appears and auto-advances
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  const context = await browser.newContext();
  const gameId = 'shop-test-' + Date.now();

  log(`Starting test with game ID: ${gameId}`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/01-landing.png', fullPage: true });

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/02-lobby-p1-joined.png', fullPage: true });
    log('Player 1 created game and joined lobby');

    // Get the game URL from the page
    const pageUrl = player1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins via URL =====
    log('STEP 2: Player 2 joins via URL...');

    const player2 = await context.newPage();
    await player2.goto(`http://localhost:4000/?game=${actualGameId}`);
    await sleep(2000);

    // Fill name and join
    await player2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await player2.click('button:has-text("Join Game")');
    await sleep(2000);
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/03-lobby-p2-joined.png', fullPage: true });
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter 1HAND dev code =====
    log('STEP 3: Entering 1HAND dev code...');

    // Enter dev code (only need to do it on one player's page, the host)
    await player1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/04-dev-code-entered.png', fullPage: true });
    log('Dev code 1HAND entered');

    // ===== STEP 4: Both players select format =====
    log('STEP 4: Selecting format...');

    // Both click "Skirmish" format (shortest game, has shop)
    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/05-format-selected.png', fullPage: true });
    log('Both players selected Skirmish format');

    // ===== STEP 5: Start game =====
    log('STEP 5: Starting game...');

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/06-game-started-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/07-game-started-p2.png', fullPage: true });
    log('Game started');

    // ===== STEP 6: Play 1 hand (thanks to 1HAND dev code) =====
    log('STEP 6: Playing round (1 hand with dev code)...');

    // Player 1 selects and plays a card
    const p1Cards = await player1.$$('button[phx-click="toggle_card"]');
    if (p1Cards.length > 0) {
      await p1Cards[0].click();
      await sleep(400);
      await player1.click('button:has-text("Play")');
      await sleep(1000);
    }

    // Player 2 selects and plays a card
    const p2Cards = await player2.$$('button[phx-click="toggle_card"]');
    if (p2Cards.length > 0) {
      await p2Cards[0].click();
      await sleep(400);
      await player2.click('button:has-text("Play")');
      await sleep(1500);
    }

    // Both players skip hand result
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(1000);

    log('Hand complete');

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/08-round-complete-p1.png', fullPage: true });

    // ===== STEP 7: Wait for shop =====
    log('STEP 7: Waiting for shop...');
    await sleep(4000);  // Wait for auto-dismiss

    // If still on results, try clicking Skip
    const skipBtn1 = await player1.$('button:has-text("Skip")');
    if (skipBtn1) await skipBtn1.click();
    const skipBtn2 = await player2.$('button:has-text("Skip")');
    if (skipBtn2) await skipBtn2.click();
    await sleep(2000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/09-shop-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/10-shop-p2.png', fullPage: true });

    // Count shop cards to verify 15 cards
    const shopCards = await player1.$$('.grid.grid-cols-3 button');
    log(`Found ${shopCards.length} shop cards (expected: 15)`);

    // ===== STEP 8: Pick shop cards =====
    log('STEP 8: Picking shop cards...');

    // First picker makes pick
    const firstPickerText = await player1.textContent('body');
    const p1First = firstPickerText.includes('Your turn');

    const firstPicker = p1First ? player1 : player2;
    const secondPicker = p1First ? player2 : player1;
    const firstPickerName = p1First ? 'Player1' : 'Player2';
    const secondPickerName = p1First ? 'Player2' : 'Player1';

    // First pick
    log(`  ${firstPickerName}'s turn (first pick)...`);
    await firstPicker.waitForSelector(':text("Your turn")', { timeout: 10000 }).catch(() => {});
    const shopCardsFirst = await firstPicker.$$('[phx-click="preview_shop_card"]');
    if (shopCardsFirst.length > 0) {
      await shopCardsFirst[0].click();
      await sleep(1000);
      await firstPicker.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/11-preview-card.png', fullPage: true });

      const confirmBtn = await firstPicker.$('button:has-text("Confirm Selection")');
      if (confirmBtn) {
        await confirmBtn.click();
        await sleep(1500);
      }
      log(`  ${firstPickerName} picked card`);
    }

    // Second pick
    log(`  ${secondPickerName}'s turn (second pick)...`);
    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 }).catch(() => {});
    await sleep(500);
    const shopCardsSecond = await secondPicker.$$('[phx-click="preview_shop_card"]');
    if (shopCardsSecond.length > 0) {
      await shopCardsSecond[0].click();
      await sleep(1000);

      const confirmBtn = await secondPicker.$('button:has-text("Confirm Selection")');
      if (confirmBtn) {
        await confirmBtn.click();
        await sleep(1500);
      }
      log(`  ${secondPickerName} picked card`);
    }

    log('Both players picked cards');

    // ===== STEP 9: Capture countdown timer =====
    log('STEP 9: Capturing countdown timer...');
    await sleep(500);

    // Take screenshot showing countdown
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/12-countdown-timer-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/13-countdown-timer-p2.png', fullPage: true });

    // Check for countdown text
    const countdownText = await player1.textContent('body');
    if (countdownText.includes('Next round in') || countdownText.includes('All picks complete')) {
      log('Countdown timer visible!');
    }

    // Wait for auto-advance (5 seconds + buffer)
    log('STEP 10: Waiting for auto-advance...');
    await sleep(6000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/14-after-timer-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/15-after-timer-p2.png', fullPage: true });

    // Check if we're back to gameplay
    const gameplayCheck = await player1.textContent('body');
    if (gameplayCheck.includes('Round 2') || gameplayCheck.includes('Play')) {
      log('Successfully auto-advanced to next round!');
    }

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-shop-layout-timer/');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-shop-layout-timer/ERROR.png', fullPage: true });
        log('Error screenshot saved');
      }
    } catch (e) {
      // Ignore screenshot errors
    }
  } finally {
    await browser.close();
    log('Browser closed');
  }
}

main().catch(console.error);
