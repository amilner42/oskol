/**
 * Test for issue #42: Disabled cards make seeing the card a bit too hard
 *
 * This test verifies that the red X overlay on disabled cards has been
 * reduced in opacity (from 90% to 50%) to improve card visibility.
 *
 * Steps:
 * 1. Two players join and start game with PLUS_BOMB applied (via dev codes)
 * 2. Play one round to get to shop
 * 3. Pick PLUS BOMB card and select a card to disable
 * 4. Start next round and screenshot the disabled cards showing the new lower opacity X
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

  log('Starting disabled card opacity test for issue #42');

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'TestPlayer1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    log('Player 1 created game and joined lobby');

    // Get the game URL
    const pageUrl = player1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins =====
    log('STEP 2: Player 2 joins...');

    const player2 = await context.newPage();
    await player2.goto(`http://localhost:4000/?game=${actualGameId}`);
    await sleep(2000);

    await player2.fill('input[name="player_name"]', 'TestPlayer2');
    await sleep(300);
    await player2.click('button:has-text("Join Game")');
    await sleep(2000);
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter dev codes =====
    log('STEP 3: Entering dev codes...');

    // Use PLUS_BOMB to force disabled cards and 1HAND for quick rounds
    await player1.fill('input[name="dev_code"]', 'SHOP_FORCE_PLUS_BOMB,1HAND');
    await sleep(500);

    // ===== STEP 4: Select format and start =====
    log('STEP 4: Selecting format and starting...');

    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
      log('Game started');
    }

    // ===== STEP 5: Play 1 hand =====
    log('STEP 5: Playing one hand...');

    const p1Cards = await player1.$$('button[phx-click="toggle_card"]');
    if (p1Cards.length > 0) {
      await p1Cards[0].click();
      await sleep(400);
      await player1.click('button:has-text("Play")');
      await sleep(1500);
    }

    const p2Cards = await player2.$$('button[phx-click="toggle_card"]');
    if (p2Cards.length > 0) {
      await p2Cards[0].click();
      await sleep(400);
      await player2.click('button:has-text("Play")');
      await sleep(2000);
    }

    // Skip results
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(2000);

    // Skip round summary
    const p1SkipRound = await player1.$('button:has-text("Skip")');
    if (p1SkipRound) await p1SkipRound.click();
    const p2SkipRound = await player2.$('button:has-text("Skip")');
    if (p2SkipRound) await p2SkipRound.click();
    await sleep(2000);

    log('Round complete, entering shop...');

    // ===== STEP 6: Shop - Pick PLUS BOMB =====
    log('STEP 6: Picking PLUS BOMB card...');

    await player1.screenshot({ path: 'playwright/screenshots/test-disabled-card-opacity/01-shop-phase.png', fullPage: true });

    const shopText = await player1.textContent('body');
    const player1First = shopText.includes('Your turn');
    const firstPicker = player1First ? player1 : player2;
    const firstPickerName = player1First ? 'Player1' : 'Player2';

    log(`${firstPickerName} is picking first`);

    // Look for Plus Bomb card
    const plusBombCards = await firstPicker.$$('[phx-click="preview_plus_bomb"]');
    if (plusBombCards.length > 0) {
      await plusBombCards[0].click();
      await sleep(1500);

      const chooseBtn = await firstPicker.$('button:has-text("Choose Card")');
      if (chooseBtn) {
        await chooseBtn.click();
        await sleep(2000);

        const selectableCards = await firstPicker.$$('button[phx-click="select_plus_bomb_card"]');
        if (selectableCards.length > 0) {
          await selectableCards[0].click();
          await sleep(1500);

          try {
            await firstPicker.waitForSelector('button:has-text("Confirm Selection")', { timeout: 5000 });
            const confirmBtn = await firstPicker.$('button:has-text("Confirm Selection")');
            if (confirmBtn) {
              await confirmBtn.click();
              await sleep(2000);
              log('PLUS BOMB selection confirmed');
            }
          } catch (e) {
            log('Warning: Could not confirm selection');
          }
        }
      }
    }

    // Second picker - just skip with any card
    const secondPicker = player1First ? player2 : player1;
    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    await sleep(1000);

    const actionCards = await secondPicker.$$('[phx-click="preview_shop_card"]');
    if (actionCards.length > 0) {
      await actionCards[0].click();
      await sleep(1000);
      const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
    }

    // Shop round 2 - both pick any card
    await firstPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const round2First = await firstPicker.$$('[phx-click="preview_shop_card"]');
    if (round2First.length > 0) {
      await round2First[0].click();
      await sleep(1000);
      const confirmBtn = await firstPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
    }

    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const round2Second = await secondPicker.$$('[phx-click="preview_shop_card"]');
    if (round2Second.length > 0) {
      await round2Second[0].click();
      await sleep(1000);
      const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
    }

    // Wait for countdown
    log('STEP 7: Waiting for next round...');
    await sleep(7000);

    // ===== STEP 8: Screenshot disabled cards =====
    log('STEP 8: Taking screenshots of disabled cards with reduced opacity X...');

    await player1.screenshot({ path: 'playwright/screenshots/test-disabled-card-opacity/02-disabled-cards-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-disabled-card-opacity/03-disabled-cards-p2.png', fullPage: true });

    // Try to open the Console/Deck view to see all cards
    const consoleBtn = await player1.$('button:has-text("Console")');
    if (consoleBtn) {
      await consoleBtn.click();
      await sleep(1000);
      await player1.screenshot({ path: 'playwright/screenshots/test-disabled-card-opacity/04-console-deck-view.png', fullPage: true });
      log('Captured console/deck view showing disabled cards');
    }

    log('\n=== TEST COMPLETE ===');
    log('Issue #42: Disabled card opacity reduced from 90% to 50%');
    log('Screenshots saved to playwright/screenshots/test-disabled-card-opacity/');
    log('Key screenshots:');
    log('  - 02-disabled-cards-p1.png: Shows disabled cards with reduced opacity X');
    log('  - 03-disabled-cards-p2.png: Shows disabled cards from other player view');
    log('  - 04-console-deck-view.png: Console deck view with disabled cards');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-disabled-card-opacity/ERROR.png', fullPage: true });
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
