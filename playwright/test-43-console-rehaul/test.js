const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const PORT = 4001;
const SCREENSHOT_DIR = 'playwright/screenshots/test-43-console-rehaul';

(async () => {
  // Clean screenshots directory before starting
  if (fs.existsSync(SCREENSHOT_DIR)) {
    fs.rmSync(SCREENSHOT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  const browser = await chromium.launch({ headless: true });

  // Test on desktop viewport
  const desktopPage = await browser.newPage({ viewport: { width: 1920, height: 1080 } });

  console.log('Testing desktop viewport...');

  // Navigate to landing page
  await desktopPage.goto(`http://localhost:${PORT}`);
  await desktopPage.waitForLoadState('networkidle');
  await desktopPage.screenshot({
    path: path.join(SCREENSHOT_DIR, '01-desktop-landing.png'),
    fullPage: true
  });

  // Create a game
  const gameId = 'test-console-' + Date.now();
  await desktopPage.goto(`http://localhost:${PORT}/?game=${gameId}`);
  await desktopPage.waitForLoadState('networkidle');

  // Enter player name
  await desktopPage.fill('input[name="player_name"]', 'Alice');
  await desktopPage.click('button:has-text("Join Game")');
  await desktopPage.waitForTimeout(1000);

  // Open second player in a new page
  const player2Page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  await player2Page.goto(`http://localhost:${PORT}/?game=${gameId}`);
  await player2Page.waitForLoadState('networkidle');
  await player2Page.fill('input[name="player_name"]', 'Bob');
  await player2Page.click('button:has-text("Join Game")');
  await player2Page.waitForTimeout(1000);

  await desktopPage.screenshot({
    path: path.join(SCREENSHOT_DIR, '02-desktop-lobby.png'),
    fullPage: true
  });

  // Both players need to select the same game mode
  // Click on "Battle" for both players
  await desktopPage.click('button:has-text("Battle")');
  await desktopPage.waitForTimeout(300);
  await player2Page.click('button:has-text("Battle")');
  await player2Page.waitForTimeout(300);

  // Now Start Game should be enabled
  await desktopPage.click('button:has-text("Start Game")');
  await desktopPage.waitForTimeout(4000); // Wait for game to start

  // Take screenshot of initial game state showing console buttons at bottom
  await desktopPage.screenshot({
    path: path.join(SCREENSHOT_DIR, '03-desktop-game-showing-emoji-buttons.png'),
    fullPage: true
  });

  // Test clicking on each console button to show the new design

  // Click on Deck button (📦)
  const deckButton = await desktopPage.locator('button:has-text("📦")');
  if (await deckButton.count() > 0) {
    await deckButton.click();
    await desktopPage.waitForTimeout(500);

    await desktopPage.screenshot({
      path: path.join(SCREENSHOT_DIR, '04-desktop-deck-console-in-centerboard.png'),
      fullPage: true
    });

    // Close console by clicking same button (toggle off)
    await deckButton.click();
    await desktopPage.waitForTimeout(500);
  }

  // Click on Levels button (⭐)
  const levelsButton = await desktopPage.locator('button:has-text("⭐")');
  if (await levelsButton.count() > 0) {
    await levelsButton.click();
    await desktopPage.waitForTimeout(500);

    await desktopPage.screenshot({
      path: path.join(SCREENSHOT_DIR, '05-desktop-levels-console-in-centerboard.png'),
      fullPage: true
    });

    // Close by toggling
    await levelsButton.click();
    await desktopPage.waitForTimeout(500);
  }

  // Click on Log button (📰)
  const logButton = await desktopPage.locator('button:has-text("📰")');
  if (await logButton.count() > 0) {
    await logButton.click();
    await desktopPage.waitForTimeout(500);

    await desktopPage.screenshot({
      path: path.join(SCREENSHOT_DIR, '06-desktop-log-console-in-centerboard.png'),
      fullPage: true
    });

    // Close by toggling
    await logButton.click();
    await desktopPage.waitForTimeout(500);
  }

  // Test mobile viewport
  console.log('Testing mobile viewport...');

  const mobilePage = await browser.newPage({ viewport: { width: 375, height: 812 } });
  // Use same approach as desktop - create new game session
  const mobileGameId = 'test-console-mobile-' + Date.now();
  await mobilePage.goto(`http://localhost:${PORT}/?game=${mobileGameId}`);
  await mobilePage.waitForLoadState('networkidle');

  // Enter player name
  await mobilePage.fill('input[name="player_name"]', 'MobileAlice');
  await mobilePage.click('button:has-text("Join Game")');
  await mobilePage.waitForTimeout(1000);

  // Second player for mobile game
  const mobilePlayer2Page = await browser.newPage({ viewport: { width: 375, height: 812 } });
  await mobilePlayer2Page.goto(`http://localhost:${PORT}/?game=${mobileGameId}`);
  await mobilePlayer2Page.waitForLoadState('networkidle');
  await mobilePlayer2Page.fill('input[name="player_name"]', 'MobileBob');
  await mobilePlayer2Page.click('button:has-text("Join Game")');
  await mobilePlayer2Page.waitForTimeout(1000);

  // Both players select Battle mode
  await mobilePage.click('button:has-text("Battle")');
  await mobilePage.waitForTimeout(300);
  await mobilePlayer2Page.click('button:has-text("Battle")');
  await mobilePlayer2Page.waitForTimeout(300);

  // Start game
  await mobilePage.click('button:has-text("Start Game")');
  await mobilePage.waitForTimeout(4000);

  await mobilePage.screenshot({
    path: path.join(SCREENSHOT_DIR, '07-mobile-game-with-emoji-buttons.png'),
    fullPage: true
  });

  // Click on Deck button
  const mobileDeckButton = await mobilePage.locator('button:has-text("📦")');
  if (await mobileDeckButton.count() > 0) {
    await mobileDeckButton.click();
    await mobilePage.waitForTimeout(500);

    await mobilePage.screenshot({
      path: path.join(SCREENSHOT_DIR, '08-mobile-deck-console-in-centerboard.png'),
      fullPage: true
    });

    // Close using mobile close button (✕)
    const closeButton = await mobilePage.locator('button:has-text("✕")');
    if (await closeButton.count() > 0) {
      await closeButton.click();
      await mobilePage.waitForTimeout(500);
    }
  }

  // Click on Levels
  const mobileLevelsButton = await mobilePage.locator('button:has-text("⭐")');
  if (await mobileLevelsButton.count() > 0) {
    await mobileLevelsButton.click();
    await mobilePage.waitForTimeout(500);

    await mobilePage.screenshot({
      path: path.join(SCREENSHOT_DIR, '09-mobile-levels-console-in-centerboard.png'),
      fullPage: true
    });

    // Close using mobile close button (✕)
    const closeButton = await mobilePage.locator('button:has-text("✕")');
    if (await closeButton.count() > 0) {
      await closeButton.click();
      await mobilePage.waitForTimeout(500);
    }
  }

  // Click on Log
  const mobileLogButton = await mobilePage.locator('button:has-text("📰")');
  if (await mobileLogButton.count() > 0) {
    await mobileLogButton.click();
    await mobilePage.waitForTimeout(500);

    await mobilePage.screenshot({
      path: path.join(SCREENSHOT_DIR, '10-mobile-log-console-in-centerboard.png'),
      fullPage: true
    });
  }

  await mobilePlayer2Page.close();

  console.log('✅ All screenshots captured successfully!');
  await browser.close();
})();
