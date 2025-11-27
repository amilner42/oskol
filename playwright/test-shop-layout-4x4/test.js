const { chromium } = require('playwright');

// Helper to sleep
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });
  const page = await browser.newPage();

  try {
    console.log('Testing shop layout with 4x4 grid...');

    // Navigate to the home page
    await page.goto('http://localhost:4000');
    await sleep(2000);

    // Create a game
    console.log('Creating game...');
    await page.fill('input[placeholder="enter your nickname"]', 'TestPlayer1');
    await page.click('button:has-text("New Game")');
    await sleep(2000);

    // Take screenshot of lobby
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/01-lobby.png', fullPage: true });
    console.log('Screenshot saved: 01-lobby.png');

    // Get the game code - try to find it in the page text
    const bodyText = await page.textContent('body');
    const gameCodeMatch = bodyText.match(/[A-Z]{4}/);
    const gameCode = gameCodeMatch ? gameCodeMatch[0] : null;
    console.log(`Game code: ${gameCode}`);

    // Open a new page for player 2
    const context = await browser.newContext();
    const page2 = await context.newPage();
    await page2.goto('http://localhost:4000');
    await sleep(2000);

    // Join the game with player 2
    console.log('Joining game with second player...');
    const inputs2 = await page2.$$('input');
    if (inputs2.length >= 2) {
      await inputs2[0].fill('TestPlayer2'); // nickname
      await inputs2[1].fill(gameCode.trim()); // game code
    }
    await page2.click('button:has-text("Join")');
    await sleep(1500);

    // Set shop rounds to 1
    console.log('Configuring shop rounds...');
    await page.click('button:has-text("1")'); // Select 1 shop round
    await sleep(500);

    // Start the game
    console.log('Starting game...');
    await page.click('button:has-text("Start Game")');
    await sleep(2000);

    // Take screenshot of game start
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/02-game-start.png', fullPage: true });
    console.log('Screenshot saved: 02-game-start.png');

    // Play through first round quickly
    console.log('Playing first round...');

    // Player 1 selects 5 cards and locks in
    const cards1 = await page.$$('[phx-click="toggle_card_selection"]');
    console.log(`Player 1 has ${cards1.length} cards available`);
    for (let i = 0; i < Math.min(5, cards1.length); i++) {
      await cards1[i].click();
      await sleep(100);
    }
    await page.click('button[phx-click="lock_in_hand"]');
    await sleep(1000);

    // Player 2 selects 5 cards and locks in
    const cards2 = await page2.$$('[phx-click="toggle_card_selection"]');
    console.log(`Player 2 has ${cards2.length} cards available`);
    for (let i = 0; i < Math.min(5, cards2.length); i++) {
      await cards2[i].click();
      await sleep(100);
    }
    await page2.click('button[phx-click="lock_in_hand"]');
    await sleep(2000);

    // Wait for round end and shop to appear
    console.log('Waiting for shop to appear...');
    await sleep(3000);

    // Click continue to shop
    const continueButtons = await page.$$('button:has-text("Continue")');
    if (continueButtons.length > 0) {
      await continueButtons[0].click();
      await sleep(1000);
    }

    // Take screenshot of shop screen - this is the main test
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/03-shop-layout.png', fullPage: true });
    console.log('Screenshot saved: 03-shop-layout.png');

    // Verify the shop layout structure
    console.log('Verifying shop layout...');

    // Check for Arsenal section
    const shopPageText = await page.textContent('body');
    const arsenalSection = shopPageText.includes('Arsenal');
    console.log(`Arsenal section visible: ${arsenalSection}`);

    // Check for Tactical Ops section
    const tacticalOpsSection = shopPageText.includes('Tactical Ops');
    console.log(`Tactical Ops section visible: ${tacticalOpsSection}`);

    // Count shop cards using button selectors
    const previewCards = await page.$$('button[phx-click="preview_shop_card"], button[phx-click="preview_deck_builder"], button[phx-click="preview_plus_bomb"]');
    console.log(`Total shop cards visible: ${previewCards.length}`);

    // Click on a card to see the preview
    console.log('Testing card preview...');
    if (previewCards.length > 0) {
      await previewCards[0].click();
      await sleep(500);
    }

    // Take screenshot of card preview
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/04-card-preview.png', fullPage: true });
    console.log('Screenshot saved: 04-card-preview.png');

    console.log('\n✅ Test completed successfully!');
    console.log('📸 Screenshots saved to playwright/test-shop-layout-4x4/');

  } catch (error) {
    console.error('❌ Test failed:', error);
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/error.png', fullPage: true });
    throw error;
  } finally {
    await browser.close();
  }
})();
