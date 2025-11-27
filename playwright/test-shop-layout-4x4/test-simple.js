/**
 * Test for 4x4 shop layout with Arsenal and Tactical Ops sections
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
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext();
  const gameId = 'shop-test-' + Date.now();

  log(`Starting shop layout test with game ID: ${gameId}`);

  try {
    // ===== STEP 1: Players join lobby =====
    log('STEP 1: Setting up 2-player game...');

    const player1 = await context.newPage();
    await player1.goto(`http://localhost:4000/g/${gameId}`);
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/01-lobby-initial.png', fullPage: true });

    await player1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await player1.click('button[type="submit"]');
    await sleep(2000);
    log('✓ Player 1 joined');

    const player2 = await context.newPage();
    await player2.goto(`http://localhost:4000/g/${gameId}`);
    await sleep(2000);

    await player2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await player2.click('button[type="submit"]');
    await sleep(2000);

    await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/02-both-joined.png', fullPage: true });
    log('✓ Both players in lobby');

    // ===== STEP 2: Configure and start game =====
    log('STEP 2: Configuring shop and starting game...');

    // Set shop rounds to 1
    const shopButtons = await player1.$$('button');
    for (const btn of shopButtons) {
      const text = await btn.textContent();
      if (text && text.trim() === '1') {
        await btn.click();
        await sleep(500);
        break;
      }
    }

    const startButton = await player1.waitForSelector('button:has-text("Start Game")', { timeout: 5000 });
    await startButton.click();
    await sleep(3000);

    await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/03-game-started.png', fullPage: true });
    log('✓ Game started');

    // ===== STEP 3: Play one round quickly =====
    log('STEP 3: Playing first round...');

    // Player 1 selects 5 cards and locks in
    const cards1 = await player1.$$('button[phx-click="toggle_card_selection"]');
    log(`  Player 1 has ${cards1.length} cards available`);
    for (let i = 0; i < Math.min(5, cards1.length); i++) {
      await cards1[i].click();
      await sleep(100);
    }
    await player1.click('button[phx-click="lock_in_hand"]');
    await sleep(1000);
    log('  ✓ Player 1 locked in hand');

    // Player 2 selects 5 cards and locks in
    const cards2 = await player2.$$('button[phx-click="toggle_card_selection"]');
    log(`  Player 2 has ${cards2.length} cards available`);
    for (let i = 0; i < Math.min(5, cards2.length); i++) {
      await cards2[i].click();
      await sleep(100);
    }
    await player2.click('button[phx-click="lock_in_hand"]');
    await sleep(3000);
    log('  ✓ Player 2 locked in hand');

    // ===== STEP 4: Navigate to shop =====
    log('STEP 4: Navigating to shop...');
    await sleep(2000);

    // Click continue to shop if available
    const continueButtons1 = await player1.$$('button:has-text("Continue")');
    if (continueButtons1.length > 0) {
      await continueButtons1[0].click();
      await sleep(2000);
    }

    await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/04-shop-layout.png', fullPage: true });
    log('✓ Shop screen captured');

    // ===== STEP 5: Verify shop layout =====
    log('STEP 5: Verifying shop layout...');

    const bodyText = await player1.textContent('body');

    const hasArsenal = bodyText.includes('Arsenal');
    const hasTacticalOps = bodyText.includes('Tactical Ops');
    const hasPermanent = bodyText.includes('Permanent Upgrades');
    const hasTactical = bodyText.includes('Tactical') || bodyText.includes('Battlefield');

    log(`  Arsenal section: ${hasArsenal ? '✓' : '✗'}`);
    log(`  Tactical Ops section: ${hasTacticalOps ? '✓' : '✗'}`);
    log(`  Permanent Upgrades text: ${hasPermanent ? '✓' : '✗'}`);
    log(`  Battlefield/Tactical text: ${hasTactical ? '✓' : '✗'}`);

    // Count shop cards
    const shopCards = await player1.$$('button[phx-click="preview_shop_card"], button[phx-click="preview_deck_builder"], button[phx-click="preview_plus_bomb"]');
    log(`  Total shop cards: ${shopCards.length}`);

    // Click on a card to preview
    if (shopCards.length > 0) {
      await shopCards[0].click();
      await sleep(500);
      await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/05-card-preview.png', fullPage: true });
      log('✓ Card preview captured');
    }

    // Click on a card from the bottom section (tactical ops)
    if (shopCards.length >= 12) {
      await shopCards[10].click(); // 11th card should be in tactical ops section
      await sleep(500);
      await player1.screenshot({ path: 'playwright/test-shop-layout-4x4/06-tactical-card-preview.png', fullPage: true });
      log('✓ Tactical card preview captured');
    }

    log('\n✅ Test completed successfully!');
    log('📸 Screenshots saved to playwright/test-shop-layout-4x4/');

  } catch (error) {
    log(`❌ Test failed: ${error.message}`);
    console.error(error);
    process.exit(1);
  } finally {
    await browser.close();
  }
}

main();
