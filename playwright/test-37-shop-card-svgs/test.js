const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// Change this to match the port your server is running on
const PORT = 4002; // Update this based on available port
const SCREENSHOT_DIR = 'playwright/screenshots/test-37-shop-card-svgs';

(async () => {
  // Clean screenshots directory before starting
  if (fs.existsSync(SCREENSHOT_DIR)) {
    fs.rmSync(SCREENSHOT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 }
  });
  const page = await context.newPage();

  try {
    // Navigate to landing page
    await page.goto(`http://localhost:${PORT}`);
    await page.waitForTimeout(1000);

    // Enter player name and start game
    await page.fill('input[name="player_name"]', 'Player1');
    await page.click('button:has-text("New Game")');
    await page.waitForTimeout(2000);

    // Use dev code to start shop immediately
    await page.fill('input[type="text"]', 'SHOP_FORCE_SCRAMBLER');
    await page.press('input[type="text"]', 'Enter');
    await page.waitForTimeout(3000);

    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '01-lobby-with-code.png'),
      fullPage: true
    });

    // Dev code should take us directly to shop
    // Wait for shop to load
    await page.waitForTimeout(2000);

    // Take full shop screenshot
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '02-shop-overview.png'),
      fullPage: true
    });

    // Take screenshot of Arsenal section (permanent upgrades - first 8 cards)
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '03-arsenal-cards.png'),
      fullPage: false,
      clip: { x: 0, y: 100, width: 600, height: 500 }
    });

    // Take screenshot of Tactical Ops section (action cards - last 4 cards)
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '04-tactical-ops-cards.png'),
      fullPage: false,
      clip: { x: 0, y: 600, width: 600, height: 400 }
    });

    // Click on different card types to see them in detail
    // Click on a level up card (e.g., Two Pair)
    const levelUpCard = await page.locator('text=Two Pair').first();
    if (await levelUpCard.isVisible()) {
      await levelUpCard.click();
      await page.waitForTimeout(1000);
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, '05-level-up-card-detail.png'),
        fullPage: true
      });
    }

    // Go back to grid view and try another card type
    // Look for a deck builder card
    const deckBuilderCard = await page.locator('text=Add Card').first();
    if (await deckBuilderCard.isVisible()) {
      await deckBuilderCard.click();
      await page.waitForTimeout(1000);
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, '06-deck-builder-card.png'),
        fullPage: true
      });
    }

    // Try to find a sabotage card
    const sabotageCard = await page.locator('text=Scrambler').or(page.locator('text=Plus Bomb')).or(page.locator('text=Static Field')).first();
    if (await sabotageCard.isVisible()) {
      await sabotageCard.click();
      await page.waitForTimeout(1000);
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, '07-sabotage-card.png'),
        fullPage: true
      });
    }

    // Try to find a counter/denial card
    const denialCard = await page.locator('button:has-text("COUNTER")').first();
    if (await denialCard.isVisible()) {
      await denialCard.click();
      await page.waitForTimeout(1000);
      await page.screenshot({
        path: path.join(SCREENSHOT_DIR, '08-counter-card.png'),
        fullPage: true
      });
    }

    // Mobile view test
    await context.close();
    const mobileContext = await browser.newContext({
      viewport: { width: 375, height: 667 }
    });
    const mobilePage = await mobileContext.newPage();

    // Navigate back to game (might need to restart)
    await mobilePage.goto(`http://localhost:${PORT}`);
    await mobilePage.waitForTimeout(1000);
    await mobilePage.fill('input[name="player_name"]', 'MobilePlayer');
    await mobilePage.click('button:has-text("New Game")');
    await mobilePage.waitForTimeout(2000);

    // Use dev code
    await mobilePage.fill('input[type="text"]', 'SHOP_FORCE_SCRAMBLER');
    await mobilePage.press('input[type="text"]', 'Enter');
    await mobilePage.waitForTimeout(3000);

    // Mobile shop view
    await mobilePage.screenshot({
      path: path.join(SCREENSHOT_DIR, '09-mobile-shop.png'),
      fullPage: true
    });

    console.log('✅ All screenshots captured successfully!');

  } catch (error) {
    console.error('❌ Error during test:', error);
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, 'error.png'),
      fullPage: true
    });
  } finally {
    await browser.close();
  }
})();
