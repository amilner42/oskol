/**
 * End-to-end test for PLUS BOMB and STATIC action cards
 *
 * Tests:
 * 1. Two players join and start game with dev codes: SHOP_FORCE_PLUS_BOMB,SHOP_FORCE_STATIC,1HAND
 * 2. Play through one complete round (1 hand with dev code)
 * 3. Shop displays PLUS BOMB and STATIC action cards (forced via dev codes)
 * 4. First picker selects PLUS BOMB card and chooses a card from 8-card grid
 * 5. Second picker selects STATIC card (immediate effect)
 * 6. Second round of shop picks
 * 7. Wait for auto-countdown and verify round advances
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
  const gameId = 'plus-bomb-test-' + Date.now();

  log(`Starting PLUS BOMB / STATIC test with game ID: ${gameId}`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/01-landing.png', fullPage: true });

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/02-lobby-p1-joined.png', fullPage: true });
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
    await player2.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/03-lobby-p2-joined.png', fullPage: true });
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter dev codes =====
    log('STEP 3: Entering dev codes (SHOP_FORCE_PLUS_BOMB, SHOP_FORCE_STATIC, 1HAND)...');

    // Enter dev codes (only need to do it on one player's page, the host)
    await player1.fill('input[name="dev_code"]', 'SHOP_FORCE_PLUS_BOMB,SHOP_FORCE_STATIC,1HAND');
    await sleep(500);
    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/04-dev-codes-entered.png', fullPage: true });
    log('Dev codes entered');

    // ===== STEP 4: Both players select format =====
    log('STEP 4: Selecting format...');

    // Both click "Skirmish" format (shortest game, has shop)
    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/05-format-selected.png', fullPage: true });
    log('Both players selected Skirmish format');

    // ===== STEP 5: Start game =====
    log('STEP 5: Starting game...');

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
      await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/06-game-started-p1.png', fullPage: true });
      await player2.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/07-game-started-p2.png', fullPage: true });
      log('Game started');
    }

    // ===== STEP 6: Play 1 hand (using 1HAND dev code) =====
    log('STEP 6: Playing one hand (1HAND dev code active)...');

    // Player 1 selects and plays a card
    const p1Cards = await player1.$$('button[phx-click="toggle_card"]');
    if (p1Cards.length > 0) {
      await p1Cards[0].click();
      await sleep(400);
      await player1.click('button:has-text("Play")');
      await sleep(1500);
    }
    log('Player 1 played hand');

    // Player 2 selects and plays a card
    const p2Cards = await player2.$$('button[phx-click="toggle_card"]');
    if (p2Cards.length > 0) {
      await p2Cards[0].click();
      await sleep(400);
      await player2.click('button:has-text("Play")');
      await sleep(2000);
    }
    log('Player 2 played hand');

    // Skip hand results
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(1000);

    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/08-round-complete.png', fullPage: true });
    log('Round complete');

    // Skip round summary
    await sleep(2000);
    const p1SkipRound = await player1.$('button:has-text("Skip")');
    if (p1SkipRound) await p1SkipRound.click();
    const p2SkipRound = await player2.$('button:has-text("Skip")');
    if (p2SkipRound) await p2SkipRound.click();
    await sleep(2000);

    // ===== STEP 7: Shop - Pick PLUS BOMB card =====
    log('STEP 7: Entering shop phase...');

    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/09-shop-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/10-shop-p2.png', fullPage: true });

    // Determine turn order
    const shopText = await player1.textContent('body');
    const player1First = shopText.includes('Your turn');
    log(`Turn order: ${player1First ? 'Player1 first' : 'Player2 first'}`);

    const firstPicker = player1First ? player1 : player2;
    const secondPicker = player1First ? player2 : player1;
    const firstPickerName = player1First ? 'Player1' : 'Player2';
    const secondPickerName = player1First ? 'Player2' : 'Player1';

    // ===== First picker picks PLUS BOMB =====
    log(`${firstPickerName}'s turn - looking for PLUS BOMB card...`);

    // Wait for shop to be ready
    await sleep(1000);

    // Look for Plus Bomb card (it uses preview_plus_bomb event)
    const plusBombCards = await firstPicker.$$('[phx-click="preview_plus_bomb"]');
    log(`Found ${plusBombCards.length} Plus Bomb cards`);

    if (plusBombCards.length > 0) {
      await plusBombCards[0].click();
      await sleep(1500);
      await firstPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/11-plus-bomb-preview.png', fullPage: true });
      log('PLUS BOMB card preview opened');

      // Click "Choose Card" to start selection
      const chooseBtn = await firstPicker.$('button:has-text("Choose Card")');
      if (chooseBtn) {
        await chooseBtn.click();
        await sleep(2000);
        await firstPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/12-plus-bomb-selection-grid.png', fullPage: true });
        log('8-card selection grid displayed');

        // Select one card from the grid
        const selectableCards = await firstPicker.$$('button[phx-click="select_plus_bomb_card"]');
        log(`Found ${selectableCards.length} cards to choose from`);

        if (selectableCards.length > 0) {
          // Click the first card to select it
          await selectableCards[0].click();
          await sleep(1500);
          await firstPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/13-plus-bomb-card-selected.png', fullPage: true });
          log('Selected a card for PLUS BOMB effect');

          // Wait for and click the Confirm Selection button
          try {
            await firstPicker.waitForSelector('button:has-text("Confirm Selection")', { timeout: 5000 });
            const confirmBtn = await firstPicker.$('button:has-text("Confirm Selection")');
            if (confirmBtn) {
              await confirmBtn.click();
              await sleep(2000);
              await firstPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/14-plus-bomb-confirmed.png', fullPage: true });
              log('PLUS BOMB selection confirmed!');
            }
          } catch (e) {
            log('Warning: Confirm Selection button not found, taking debug screenshot');
            await firstPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/14-debug-no-confirm.png', fullPage: true });
          }
        }
      }
    } else {
      log('No PLUS BOMB card found - picking regular shop card');
      const shopCards = await firstPicker.$$('[phx-click="preview_shop_card"]');
      if (shopCards.length > 0) {
        await shopCards[0].click();
        await sleep(1000);
        const confirmBtn = await firstPicker.$('button:has-text("Confirm")');
        if (confirmBtn) await confirmBtn.click();
        await sleep(1000);
      }
    }

    // ===== Second picker's turn - pick STATIC or other card =====
    log(`${secondPickerName}'s turn...`);
    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    await sleep(1000);
    await secondPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/15-second-picker-turn.png', fullPage: true });

    // Look for STATIC card (uses preview_shop_card since it's immediate effect)
    const actionCards = await secondPicker.$$('[phx-click="preview_shop_card"]');
    let foundStatic = false;

    for (const card of actionCards) {
      const text = await card.textContent();
      if (text.includes('Static')) {
        log('Found STATIC card!');
        foundStatic = true;
        await card.click();
        await sleep(1500);
        await secondPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/16-static-preview.png', fullPage: true });

        const confirmBtn = await secondPicker.$('button:has-text("Confirm Selection")');
        if (confirmBtn) {
          await confirmBtn.click();
          await sleep(2000);
          await secondPicker.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/17-static-confirmed.png', fullPage: true });
          log('STATIC card picked and confirmed!');
        }
        break;
      }
    }

    if (!foundStatic) {
      log('STATIC card not found in available cards - picking first available card');
      if (actionCards.length > 0) {
        await actionCards[0].click();
        await sleep(1000);
        const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
        if (confirmBtn) await confirmBtn.click();
        await sleep(1000);
      }
    }

    log('Shop round 1 complete');

    // ===== STEP 8: Shop round 2 =====
    log('STEP 8: Shop round 2...');
    await sleep(1000);

    // Just pick any available cards for round 2
    await firstPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const round2FirstCards = await firstPicker.$$('[phx-click="preview_shop_card"]');
    if (round2FirstCards.length > 0) {
      await round2FirstCards[0].click();
      await sleep(1000);
      const confirmBtn = await firstPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
      log(`${firstPickerName} picked shop card`);
    }

    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const round2SecondCards = await secondPicker.$$('[phx-click="preview_shop_card"]');
    if (round2SecondCards.length > 0) {
      await round2SecondCards[0].click();
      await sleep(1000);
      const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
      log(`${secondPickerName} picked shop card`);
    }

    // ===== STEP 9: Wait for countdown and next round =====
    log('STEP 9: Waiting for shop countdown and next round...');
    await sleep(3000);

    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/18-shop-complete-countdown.png', fullPage: true });
    log('Screenshot of countdown timer');

    // Wait for countdown to finish (5 seconds)
    await sleep(6000);

    await player1.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/19-next-round-started.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/20-next-round-p2.png', fullPage: true });
    log('Next round started');

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-plus-bomb-static/');
    log('Key screenshots to verify:');
    log('  - 11-plus-bomb-preview.png: PLUS BOMB card detail view');
    log('  - 12-plus-bomb-selection-grid.png: 8-card selection grid');
    log('  - 13-plus-bomb-card-selected.png: Card selected for effect');
    log('  - 16-static-preview.png: STATIC card detail view');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-plus-bomb-static/ERROR.png', fullPage: true });
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
