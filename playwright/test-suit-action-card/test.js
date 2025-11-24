/**
 * End-to-end test for suit-changing action cards
 *
 * Flow:
 * 1. Two players join and start game
 * 2. Play through one complete round (4 hands)
 * 3. Shop: Primary attempts suit-changing card, others pick level ups
 * 4. Both players ready up
 * 5. View Cards modal to verify suit changes
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
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
  });

  const context = await browser.newContext();
  const gameId = 'test-' + Date.now();

  log(`Starting test with game ID: ${gameId}`);

  try {
    // ===== STEP 1: Players join lobby =====
    log('STEP 1: Setting up 2-player game...');

    const primary = await context.newPage();
    await primary.goto(`http://localhost:4000/g/${gameId}`);
    await sleep(2000);
    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/01-lobby-initial.png', fullPage: true });

    await primary.fill('input[name="player_name"]', 'Primary');
    await sleep(300);
    await primary.click('button[type="submit"]');
    await sleep(2000);
    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/02-player1-joined.png', fullPage: true });
    log('✓ Primary joined');

    const opponent = await context.newPage();
    await opponent.goto(`http://localhost:4000/g/${gameId}`);
    await sleep(2000);

    await opponent.fill('input[name="player_name"]', 'Opponent');
    await sleep(300);
    await opponent.click('button[type="submit"]');
    await sleep(2000);

    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/03-both-joined-p1.png', fullPage: true });
    await opponent.screenshot({ path: 'playwright/screenshots/test-suit-action-card/04-both-joined-p2.png', fullPage: true });
    log('✓ Both players in lobby');

    // ===== STEP 2: Start game =====
    log('STEP 2: Starting game...');
    const startButton = await primary.waitForSelector('button:has-text("Start Game")', { timeout: 5000 });
    await startButton.click();
    await sleep(3000);

    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/05-game-started-p1.png', fullPage: true });
    await opponent.screenshot({ path: 'playwright/screenshots/test-suit-action-card/06-game-started-p2.png', fullPage: true });
    log('✓ Game started');

    // ===== STEP 3: Play 4 hands =====
    log('STEP 3: Playing first round (4 hands)...');

    for (let hand = 1; hand <= 4; hand++) {
      log(`  Playing hand ${hand}/4...`);

      // Primary selects and plays a card
      const primaryCards = await primary.$$('button[phx-click="toggle_card"]');
      if (primaryCards.length > 0) {
        await primaryCards[0].click();
        await sleep(400);
        await primary.click('button:has-text("Play")');
        await sleep(1000);
      }

      // Opponent selects and plays a card
      const opponentCards = await opponent.$$('button[phx-click="toggle_card"]');
      if (opponentCards.length > 0) {
        await opponentCards[0].click();
        await sleep(400);
        await opponent.click('button:has-text("Play")');
        await sleep(1500);
      }

      // Both players skip hand result
      const primarySkipHand = await primary.$('button:has-text("Skip")');
      if (primarySkipHand) await primarySkipHand.click();
      const opponentSkipHand = await opponent.$('button:has-text("Skip")');
      if (opponentSkipHand) await opponentSkipHand.click();
      await sleep(500);

      log(`  ✓ Hand ${hand} complete`);
    }

    log('✓ All 4 hands played');

    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/07-round-complete-p1.png', fullPage: true });
    await opponent.screenshot({ path: 'playwright/screenshots/test-suit-action-card/08-round-complete-p2.png', fullPage: true });

    // ===== STEP 4: Skip round summary =====
    log('STEP 4: Skipping round summary...');
    await sleep(2000);

    const primarySkipRound = await primary.$('button:has-text("Skip")');
    if (primarySkipRound) await primarySkipRound.click();
    const opponentSkipRound = await opponent.$('button:has-text("Skip")');
    if (opponentSkipRound) await opponentSkipRound.click();
    await sleep(2000);
    log('✓ Skipped round summary');

    // ===== STEP 5: Shop Round 1 =====
    log('STEP 5: Shop round 1/2...');
    await sleep(2000);

    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/09-shop-p1.png', fullPage: true });
    await opponent.screenshot({ path: 'playwright/screenshots/test-suit-action-card/10-shop-p2.png', fullPage: true });

    // Determine turn order for round 1
    const shopText1 = await primary.textContent('body');
    const primaryFirst1 = shopText1.includes('First Pick: Primary');
    log(`  Turn order: ${primaryFirst1 ? 'Primary → Opponent' : 'Opponent → Primary'}`);

    const firstPicker1 = primaryFirst1 ? primary : opponent;
    const secondPicker1 = primaryFirst1 ? opponent : primary;
    const firstPickerName1 = primaryFirst1 ? 'Primary' : 'Opponent';
    const secondPickerName1 = primaryFirst1 ? 'Opponent' : 'Primary';
    const firstPickerIsPrimary1 = primaryFirst1;

    // First picker's turn
    log(`  ${firstPickerName1}'s turn...`);

    if (firstPickerIsPrimary1) {
      // Primary tries to find suit-changing card
      const deckBuilderCards = await firstPicker1.$$('[phx-click="preview_deck_builder"]');
      let foundSuitCard = false;

      for (let i = 0; i < deckBuilderCards.length; i++) {
        const cardText = await deckBuilderCards[i].textContent();
        if (/[♥♦♣♠]/.test(cardText)) {
          log(`  ✓ Found suit-changing card!`);
          foundSuitCard = true;

          await deckBuilderCards[i].click();
          await sleep(2000);
          await firstPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/11-suit-card-preview.png', fullPage: true });

          const confirmBtn = await firstPicker1.$('button:has-text("Confirm Pick")');
          if (confirmBtn) {
            await confirmBtn.click();
            await sleep(2500);
            await firstPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/12-suit-card-selection.png', fullPage: true });

            // Select 3 cards
            const selectableCards = await firstPicker1.$$('button[phx-click="select_deck_card"]');
            const toSelect = Math.min(3, selectableCards.length);
            for (let j = 0; j < toSelect; j++) {
              await selectableCards[j].click();
              await sleep(400);
            }

            await firstPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/13-cards-selected.png', fullPage: true });

            const confirmSelection = await firstPicker1.$('button:has-text("Confirm Selection")');
            if (confirmSelection) {
              await confirmSelection.click();
              await sleep(2500);
              await firstPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/14-after-suit-change.png', fullPage: true });
              log(`  ✓ Primary picked suit-changing card`);
            }
          }
          break;
        }
      }

      if (!foundSuitCard) {
        log(`  ⚠ No suit-changing card available, picking another shop card`);
        await firstPicker1.waitForSelector('[phx-click="preview_shop_card"]', { timeout: 5000 });
        const shopCards = await firstPicker1.$$('[phx-click="preview_shop_card"]');
        if (shopCards.length > 0) {
          await shopCards[0].click();
          await firstPicker1.waitForSelector('button:has-text("Confirm Pick")', { timeout: 3000 });
          const confirmBtn = await firstPicker1.$('button:has-text("Confirm Pick")');
          await confirmBtn.click();
          await sleep(1000);
          log(`  ✓ Primary picked shop card`);
        }
      }
    } else {
      // Opponent picks a shop card
      // Wait for "Your turn" message to confirm it's their turn
      await firstPicker1.waitForSelector(':text("Your turn")', { timeout: 10000 });

      const shopCards = await firstPicker1.$$('[phx-click="preview_shop_card"]');
      log(`  Found ${shopCards.length} shop cards for Opponent`);

      if (shopCards.length > 0) {
        await shopCards[0].click();

        // Wait for confirm button
        await firstPicker1.waitForSelector('button:has-text("Confirm Pick")', { timeout: 5000 });
        const confirmBtn = await firstPicker1.$('button:has-text("Confirm Pick")');
        await confirmBtn.click();
        log(`  ✓ Opponent picked shop card`);
      }
    }

    // Second picker's turn
    log(`  ${secondPickerName1}'s turn...`);
    await secondPicker1.waitForSelector(':text("Your turn")', { timeout: 10000 });

    if (!firstPickerIsPrimary1) {
      // Primary tries to find suit-changing card
      const deckBuilderCards = await secondPicker1.$$('[phx-click="preview_deck_builder"]');
      let foundSuitCard = false;

      for (let i = 0; i < deckBuilderCards.length; i++) {
        const cardText = await deckBuilderCards[i].textContent();
        if (/[♥♦♣♠]/.test(cardText)) {
          log(`  ✓ Found suit-changing card!`);
          foundSuitCard = true;

          await deckBuilderCards[i].click();
          await sleep(2000);
          await secondPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/11-suit-card-preview.png', fullPage: true });

          const confirmBtn = await secondPicker1.$('button:has-text("Confirm Pick")');
          if (confirmBtn) {
            await confirmBtn.click();
            await sleep(2500);
            await secondPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/12-suit-card-selection.png', fullPage: true });

            // Select 3 cards
            const selectableCards = await secondPicker1.$$('button[phx-click="select_deck_card"]');
            const toSelect = Math.min(3, selectableCards.length);
            for (let j = 0; j < toSelect; j++) {
              await selectableCards[j].click();
              await sleep(400);
            }

            await secondPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/13-cards-selected.png', fullPage: true });

            const confirmSelection = await secondPicker1.$('button:has-text("Confirm Selection")');
            if (confirmSelection) {
              await confirmSelection.click();
              await sleep(2500);
              await secondPicker1.screenshot({ path: 'playwright/screenshots/test-suit-action-card/14-after-suit-change.png', fullPage: true });
              log(`  ✓ Primary picked suit-changing card`);
            }
          }
          break;
        }
      }

      if (!foundSuitCard) {
        log(`  ⚠ No suit-changing card available, picking another shop card`);
        await secondPicker1.waitForSelector('[phx-click="preview_shop_card"]', { timeout: 5000 });
        const shopCards = await secondPicker1.$$('[phx-click="preview_shop_card"]');
        if (shopCards.length > 0) {
          await shopCards[0].click();
          await secondPicker1.waitForSelector('button:has-text("Confirm Pick")', { timeout: 3000 });
          const confirmBtn = await secondPicker1.$('button:has-text("Confirm Pick")');
          await confirmBtn.click();
          await sleep(1000);
          log(`  ✓ Primary picked shop card`);
        }
      }
    } else {
      // Opponent picks a shop card
      const shopCards = await secondPicker1.$$('[phx-click="preview_shop_card"]');
      log(`  Found ${shopCards.length} shop cards for Opponent`);
      if (shopCards.length > 0) {
        await shopCards[0].click();
        await secondPicker1.waitForSelector('button:has-text("Confirm Pick")', { timeout: 5000 });
        const confirmBtn = await secondPicker1.$('button:has-text("Confirm Pick")');
        await confirmBtn.click();
        log(`  ✓ Opponent picked shop card`);
      }
    }

    log('✓ Shop round 1 complete');

    // ===== STEP 6: Shop Round 2 =====
    log('STEP 6: Shop round 2/2...');
    await sleep(2000);

    // Determine turn order for round 2 (may have flipped)
    const shopText2 = await primary.textContent('body');
    const primaryFirst2 = shopText2.includes('First Pick: Primary');
    log(`  Turn order: ${primaryFirst2 ? 'Primary → Opponent' : 'Opponent → Primary'}`);

    const firstPicker2 = primaryFirst2 ? primary : opponent;
    const secondPicker2 = primaryFirst2 ? opponent : primary;
    const firstPickerName2 = primaryFirst2 ? 'Primary' : 'Opponent';
    const secondPickerName2 = primaryFirst2 ? 'Opponent' : 'Primary';

    // First picker picks a shop card
    log(`  ${firstPickerName2}'s turn...`);
    await firstPicker2.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const shopCards1 = await firstPicker2.$$('[phx-click="preview_shop_card"]');
    log(`  Found ${shopCards1.length} shop cards`);
    if (shopCards1.length > 0) {
      await shopCards1[0].click();
      await firstPicker2.waitForSelector('button:has-text("Confirm Pick")', { timeout: 5000 });
      const confirmBtn = await firstPicker2.$('button:has-text("Confirm Pick")');
      await confirmBtn.click();
      log(`  ✓ ${firstPickerName2} picked shop card`);
    }

    // Second picker picks a shop card
    log(`  ${secondPickerName2}'s turn...`);
    await secondPicker2.waitForSelector(':text("Your turn")', { timeout: 10000 });
    const shopCards2 = await secondPicker2.$$('[phx-click="preview_shop_card"]');
    log(`  Found ${shopCards2.length} shop cards`);
    if (shopCards2.length > 0) {
      await shopCards2[0].click();
      await secondPicker2.waitForSelector('button:has-text("Confirm Pick")', { timeout: 5000 });
      const confirmBtn = await secondPicker2.$('button:has-text("Confirm Pick")');
      await confirmBtn.click();
      log(`  ✓ ${secondPickerName2} picked shop card`);
    }


    log('✓ Shop round 2 complete');

    // ===== STEP 7: Both players ready up =====
    log('STEP 7: Both players marking ready...');
    await sleep(2000);

    const opponentReady = await opponent.$('button:has-text("I\'m Ready!")');
    if (opponentReady) {
      await opponentReady.click();
      await sleep(1000);
      log('  ✓ Opponent marked ready');
    }

    const primaryReady = await primary.$('button:has-text("I\'m Ready!")');
    if (primaryReady) {
      await primaryReady.click();
      await sleep(3000);
      log('  ✓ Primary marked ready');
    }

    await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/15-next-round-started.png', fullPage: true });
    await opponent.screenshot({ path: 'playwright/screenshots/test-suit-action-card/16-next-round-started-p2.png', fullPage: true });
    log('✓ Next round started');

    // ===== STEP 8: Open View Cards modal =====
    log('STEP 8: Opening View Cards modal...');
    await sleep(1000);

    const viewCardsBtn = await primary.$('button:has-text("View Cards")');
    if (viewCardsBtn) {
      await viewCardsBtn.click();
      await sleep(1500);
      await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/17-view-cards-modal.png', fullPage: true });
      log('✓ Screenshot: 17-view-cards-modal.png');
      log('✓ Check this screenshot to verify suit changes on selected cards');
    } else {
      log('⚠ View Cards button not found');
      await primary.screenshot({ path: 'playwright/screenshots/test-suit-action-card/ERROR-no-view-cards.png', fullPage: true });
    }

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-suit-action-card/');
    log(`Game URL: http://localhost:4000/g/${gameId}`);

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-suit-action-card/ERROR.png', fullPage: true });
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
