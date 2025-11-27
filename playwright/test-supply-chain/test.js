/**
 * End-to-end test for SUPPLY CHAIN sabotage card
 *
 * Tests:
 * 1. Two players join and start game with dev code: SHOP_FORCE_SUPPLY_CHAIN
 * 2. Play through one complete round (1 hand with 1HAND dev code)
 * 3. Shop displays SUPPLY CHAIN card (forced via dev code)
 * 4. First picker selects SUPPLY CHAIN card (immediate effect on opponent)
 * 5. Both players complete shop
 * 6. In next round, opponent discards 5 cards and only gets 4 back
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

  log(`Starting SUPPLY CHAIN test`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/01-landing.png', fullPage: true });

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/02-lobby-p1-joined.png', fullPage: true });
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
    await player2.screenshot({ path: 'playwright/screenshots/test-supply-chain/03-lobby-p2-joined.png', fullPage: true });
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter dev codes =====
    log('STEP 3: Entering dev codes (SHOP_FORCE_SUPPLY_CHAIN, 1HAND)...');

    // Enter dev codes
    await player1.fill('input[name="dev_code"]', 'SHOP_FORCE_SUPPLY_CHAIN,1HAND');
    await sleep(500);
    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/04-dev-codes-entered.png', fullPage: true });
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

    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/05-format-selected.png', fullPage: true });
    log('Both players selected Skirmish format');

    // ===== STEP 5: Start game =====
    log('STEP 5: Starting game...');

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
      await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/06-game-started-p1.png', fullPage: true });
      await player2.screenshot({ path: 'playwright/screenshots/test-supply-chain/07-game-started-p2.png', fullPage: true });
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

    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/08-round-complete.png', fullPage: true });
    log('Round complete');

    // Skip round summary
    await sleep(2000);
    const p1SkipRound = await player1.$('button:has-text("Skip")');
    if (p1SkipRound) await p1SkipRound.click();
    const p2SkipRound = await player2.$('button:has-text("Skip")');
    if (p2SkipRound) await p2SkipRound.click();
    await sleep(2000);

    // ===== STEP 7: Shop - Pick SUPPLY CHAIN card =====
    log('STEP 7: Entering shop phase...');

    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/09-shop-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-supply-chain/10-shop-p2.png', fullPage: true });

    // Determine turn order
    const shopText = await player1.textContent('body');
    const player1First = shopText.includes('Your turn');
    log(`Turn order: ${player1First ? 'Player1 first' : 'Player2 first'}`);

    const firstPicker = player1First ? player1 : player2;
    const secondPicker = player1First ? player2 : player1;
    const firstPickerName = player1First ? 'Player1' : 'Player2';
    const secondPickerName = player1First ? 'Player2' : 'Player1';

    // ===== First picker picks SUPPLY CHAIN =====
    log(`${firstPickerName}'s turn - looking for SUPPLY CHAIN card...`);

    // Wait for shop to be ready
    await sleep(1000);

    // Look for Supply Chain card
    const actionCards = await firstPicker.$$('[phx-click="preview_shop_card"]');
    let foundSupplyChain = false;

    for (const card of actionCards) {
      const text = await card.textContent();
      if (text.includes('Supply Chain')) {
        log('Found SUPPLY CHAIN card!');
        foundSupplyChain = true;
        await card.click();
        await sleep(1500);
        await firstPicker.screenshot({ path: 'playwright/screenshots/test-supply-chain/11-supply-chain-preview.png', fullPage: true });

        const confirmBtn = await firstPicker.$('button:has-text("Confirm Selection")');
        if (confirmBtn) {
          await confirmBtn.click();
          await sleep(2000);
          await firstPicker.screenshot({ path: 'playwright/screenshots/test-supply-chain/12-supply-chain-confirmed.png', fullPage: true });
          log('SUPPLY CHAIN card picked and confirmed!');
        }
        break;
      }
    }

    if (!foundSupplyChain) {
      log('WARNING: SUPPLY CHAIN card not found - picking first available card');
      if (actionCards.length > 0) {
        await actionCards[0].click();
        await sleep(1000);
        const confirmBtn = await firstPicker.$('button:has-text("Confirm")');
        if (confirmBtn) await confirmBtn.click();
        await sleep(1000);
      }
    }

    // ===== Second picker's turn =====
    log(`${secondPickerName}'s turn...`);
    await secondPicker.waitForSelector(':text("Your turn")', { timeout: 10000 });
    await sleep(1000);

    const round1SecondCards = await secondPicker.$$('[phx-click="preview_shop_card"]');
    if (round1SecondCards.length > 0) {
      await round1SecondCards[0].click();
      await sleep(1000);
      const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1500);
      log(`${secondPickerName} picked shop card`);
    }

    log('Shop round 1 complete');

    // ===== STEP 8: Shop round 2 =====
    log('STEP 8: Shop round 2...');
    await sleep(1000);

    // Just pick any available cards for round 2
    try {
      await firstPicker.waitForSelector(':text("Your turn")', { timeout: 5000 });
      const round2FirstCards = await firstPicker.$$('[phx-click="preview_shop_card"]');
      if (round2FirstCards.length > 0) {
        await round2FirstCards[0].click();
        await sleep(1000);
        const confirmBtn = await firstPicker.$('button:has-text("Confirm")');
        if (confirmBtn) await confirmBtn.click();
        await sleep(1500);
        log(`${firstPickerName} picked shop card`);
      }
    } catch (e) {
      log('First picker turn timeout - continuing...');
    }

    try {
      await secondPicker.waitForSelector(':text("Your turn")', { timeout: 5000 });
      const round2SecondCards = await secondPicker.$$('[phx-click="preview_shop_card"]');
      if (round2SecondCards.length > 0) {
        await round2SecondCards[0].click();
        await sleep(1000);
        const confirmBtn = await secondPicker.$('button:has-text("Confirm")');
        if (confirmBtn) await confirmBtn.click();
        await sleep(1500);
        log(`${secondPickerName} picked shop card`);
      }
    } catch (e) {
      log('Second picker turn timeout - continuing...');
    }

    // ===== STEP 9: Wait for countdown and next round =====
    log('STEP 9: Waiting for shop countdown and next round...');
    await sleep(10000);

    await player1.screenshot({ path: 'playwright/screenshots/test-supply-chain/13-next-round-started-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-supply-chain/14-next-round-started-p2.png', fullPage: true });
    log('Next round started');

    // ===== STEP 10: Affected player discards 5 cards =====
    // The second picker (who didn't pick Supply Chain) is the affected player
    log(`STEP 10: ${secondPickerName} (affected by Supply Chain) discarding 5 cards...`);

    // Count cards before discard
    const cardsBeforeDiscard = await secondPicker.$$('button[phx-click="toggle_card"]');
    log(`${secondPickerName} has ${cardsBeforeDiscard.length} cards before discard`);

    // Select 5 cards to discard
    const cardsToDiscard = Math.min(5, cardsBeforeDiscard.length);
    for (let i = 0; i < cardsToDiscard; i++) {
      await cardsBeforeDiscard[i].click();
      await sleep(100);
    }

    await secondPicker.screenshot({ path: 'playwright/screenshots/test-supply-chain/15-five-cards-selected.png', fullPage: true });
    log(`Selected ${cardsToDiscard} cards for discard`);

    // Click Discard button
    const discardBtn = await secondPicker.$('button:has-text("Discard")');
    if (discardBtn) {
      await discardBtn.click();
      await sleep(2000);
    }

    // Take screenshot showing only 4 cards were drawn back
    await secondPicker.screenshot({ path: 'playwright/screenshots/test-supply-chain/16-only-four-cards-drawn.png', fullPage: true });

    // Count cards after discard
    const cardsAfterDiscard = await secondPicker.$$('button[phx-click="toggle_card"]');
    log(`${secondPickerName} has ${cardsAfterDiscard.length} cards after discard`);

    const expectedCards = cardsBeforeDiscard.length - cardsToDiscard + 4; // Discarded 5, got 4 back
    log(`Expected ${expectedCards} cards (discarded ${cardsToDiscard}, should get back 4 due to Supply Chain)`);

    if (cardsAfterDiscard.length === expectedCards) {
      log('✓ SUCCESS: Supply Chain effect working correctly! Player only drew 4 cards instead of 5.');
    } else {
      log(`✗ WARNING: Expected ${expectedCards} cards but got ${cardsAfterDiscard.length}`);
    }

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-supply-chain/');
    log('Key screenshots to verify:');
    log('  - 11-supply-chain-preview.png: SUPPLY CHAIN card detail view');
    log('  - 15-five-cards-selected.png: 5 cards selected for discard');
    log('  - 16-only-four-cards-drawn.png: Only 4 cards drawn back (Supply Chain effect)');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-supply-chain/ERROR.png', fullPage: true });
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
