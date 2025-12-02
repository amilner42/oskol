const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const PORT = 4003;
const SCREENSHOT_DIR = 'playwright/screenshots/test-60-centerboard-alignment';

(async () => {
  // Clean screenshots directory
  if (fs.existsSync(SCREENSHOT_DIR)) {
    fs.rmSync(SCREENSHOT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  // DESKTOP TEST
  console.log('Starting desktop test...');
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 }
  });

  const p1 = await context.newPage();
  const p2 = await context.newPage();

  // Player 1 creates game
  await p1.goto(`http://localhost:${PORT}`);
  await p1.waitForTimeout(1000);
  await p1.fill('input[name="player_name"]', 'Desktop1');
  await p1.click('button:has-text("New Game")');
  await p1.waitForTimeout(2000);

  // Player 2 joins
  const url = p1.url();
  await p2.goto(url);
  await p2.waitForTimeout(1000);
  await p2.fill('input[name="player_name"]', 'Desktop2');
  await p2.press('input[name="player_name"]', 'Enter');
  await p2.waitForTimeout(2000);

  // Both players select Battle mode
  await p1.click('button:has-text("Battle")');
  await p1.waitForTimeout(500);
  await p2.click('button:has-text("Battle")');
  await p2.waitForTimeout(1000);

  // Both players should now see the lobby with game modes
  // Wait for lobby_status to become ready_to_start by waiting for the enabled button
  await p1.waitForSelector('button:has-text("Start Game"):not([disabled])', { timeout: 10000 });

  await p1.screenshot({
    path: path.join(SCREENSHOT_DIR, '01-desktop-lobby-ready.png'),
    fullPage: true
  });

  // Player 1 starts the game
  await p1.click('button:has-text("Start Game")');
  await p1.waitForTimeout(3000);

  await p1.screenshot({
    path: path.join(SCREENSHOT_DIR, '02-desktop-game-started.png'),
    fullPage: true
  });

  // Both players select and play hands
  const p1Cards = await p1.locator('button[phx-click="toggle_card"]').all();
  for (let i = 0; i < Math.min(5, p1Cards.length); i++) {
    await p1Cards[i].click();
    await p1.waitForTimeout(100);
  }
  // Click the visible Play button (desktop version is in a different div)
  await p1.locator('button:has-text("Play"):visible').first().click();
  await p1.waitForTimeout(1500);

  const p2Cards = await p2.locator('button[phx-click="toggle_card"]').all();
  for (let i = 0; i < Math.min(5, p2Cards.length); i++) {
    await p2Cards[i].click();
    await p2.waitForTimeout(100);
  }
  await p2.locator('button:has-text("Play"):visible').first().click();
  await p2.waitForTimeout(5000); // Wait for scoring animation

  // CAPTURE THE SCORING DISPLAY - THIS IS THE KEY SCREENSHOT
  await p1.screenshot({
    path: path.join(SCREENSHOT_DIR, '03-desktop-scoring-ALIGNMENT-FIX.png'),
    fullPage: true
  });

  await p2.screenshot({
    path: path.join(SCREENSHOT_DIR, '04-desktop-scoring-p2.png'),
    fullPage: true
  });

  await browser.close();

  // MOBILE TEST
  console.log('Starting mobile test...');
  const mobileBrowser = await chromium.launch({ headless: true });
  const mobileContext = await mobileBrowser.newContext({
    viewport: { width: 375, height: 667 },
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15'
  });

  const m1 = await mobileContext.newPage();
  const m2 = await mobileContext.newPage();

  // Player 1 creates game
  await m1.goto(`http://localhost:${PORT}`);
  await m1.waitForTimeout(1000);
  await m1.fill('input[name="player_name"]', 'Mobile1');
  await m1.click('button:has-text("New Game")');
  await m1.waitForTimeout(2000);

  // Player 2 joins
  const mobileUrl = m1.url();
  await m2.goto(mobileUrl);
  await m2.waitForTimeout(1000);
  await m2.fill('input[name="player_name"]', 'Mobile2');
  await m2.press('input[name="player_name"]', 'Enter');
  await m2.waitForTimeout(2000);

  // Both players select Battle mode
  await m1.click('button:has-text("Battle")');
  await m1.waitForTimeout(500);
  await m2.click('button:has-text("Battle")');
  await m2.waitForTimeout(1000);

  // Wait for ready to start
  await m1.waitForSelector('button:has-text("Start Game"):not([disabled])', { timeout: 10000 });

  await m1.screenshot({
    path: path.join(SCREENSHOT_DIR, '05-mobile-lobby-ready.png'),
    fullPage: true
  });

  // Player 1 starts the game
  await m1.click('button:has-text("Start Game")');
  await m1.waitForTimeout(3000);

  await m1.screenshot({
    path: path.join(SCREENSHOT_DIR, '06-mobile-game-started.png'),
    fullPage: true
  });

  // Both players select and play hands
  const m1Cards = await m1.locator('button[phx-click="toggle_card"]').all();
  for (let i = 0; i < Math.min(5, m1Cards.length); i++) {
    await m1Cards[i].click();
    await m1.waitForTimeout(100);
  }
  await m1.locator('button:has-text("Play"):visible').first().click();
  await m1.waitForTimeout(1500);

  const m2Cards = await m2.locator('button[phx-click="toggle_card"]').all();
  for (let i = 0; i < Math.min(5, m2Cards.length); i++) {
    await m2Cards[i].click();
    await m2.waitForTimeout(100);
  }
  await m2.locator('button:has-text("Play"):visible').first().click();
  await m2.waitForTimeout(5000); // Wait for scoring animation

  // CAPTURE THE SCORING DISPLAY ON MOBILE - THIS IS THE KEY SCREENSHOT
  await m1.screenshot({
    path: path.join(SCREENSHOT_DIR, '07-mobile-scoring-ALIGNMENT-FIX.png'),
    fullPage: true
  });

  await m2.screenshot({
    path: path.join(SCREENSHOT_DIR, '08-mobile-scoring-p2.png'),
    fullPage: true
  });

  await mobileBrowser.close();

  console.log('✓ Test complete!');
  console.log('✓ Key alignment screenshots:');
  console.log('  - Desktop: 03-desktop-scoring-ALIGNMENT-FIX.png');
  console.log('  - Mobile: 07-mobile-scoring-ALIGNMENT-FIX.png');
})();
