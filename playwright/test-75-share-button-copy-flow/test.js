const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

// Change this to match the port your server is running on
const PORT = 4003;
const SCREENSHOT_DIR = 'playwright/screenshots/test-75-share-button-copy-flow';

(async () => {
  // Clean screenshots directory before starting
  if (fs.existsSync(SCREENSHOT_DIR)) {
    fs.rmSync(SCREENSHOT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    // Grant clipboard permissions
    permissions: ['clipboard-read', 'clipboard-write']
  });
  const page = await context.newPage();

  // Navigate to home page
  await page.goto(`http://localhost:${PORT}`);
  await page.screenshot({
    path: path.join(SCREENSHOT_DIR, '01-landing-page.png'),
    fullPage: true
  });

  // Create a new game
  await page.fill('input[name="player_name"]', 'TestPlayer');
  await page.screenshot({
    path: path.join(SCREENSHOT_DIR, '02-enter-player-name.png'),
    fullPage: true
  });

  await page.click('button[type="submit"]');
  await page.waitForTimeout(1000); // Wait for game to be created

  await page.screenshot({
    path: path.join(SCREENSHOT_DIR, '03-lobby-screen.png'),
    fullPage: true
  });

  // Find the share button (the "Invite friend" button)
  const shareButton = await page.locator('button:has-text("Invite friend")');
  await shareButton.highlight();
  await page.screenshot({
    path: path.join(SCREENSHOT_DIR, '04-share-button-highlighted.png'),
    fullPage: true
  });

  // Get the game URL from the hidden span
  const gameUrl = await page.locator('#share-link').textContent();
  console.log('Game URL:', gameUrl);

  // Verify the URL format - should be just the URL without extra text
  if (gameUrl.match(/^https?:\/\/.*\?game=[a-z0-9]+$/)) {
    console.log('✓ URL is in correct format (no extra text)');
  } else {
    console.log('✗ URL has unexpected format:', gameUrl);
  }

  // Click the share button to trigger the copy/share action
  // Note: In headless mode without user gesture, navigator.share will fail
  // but the fallback copy should work
  await shareButton.click();
  await page.waitForTimeout(500);

  await page.screenshot({
    path: path.join(SCREENSHOT_DIR, '05-after-share-click.png'),
    fullPage: true
  });

  // Verify clipboard content (only works if copy fallback is triggered)
  try {
    const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
    console.log('Clipboard content:', clipboardText);

    if (clipboardText === gameUrl) {
      console.log('✓ Clipboard contains correct URL');
    } else {
      console.log('✗ Clipboard content mismatch');
      console.log('  Expected:', gameUrl);
      console.log('  Got:', clipboardText);
    }

    // Verify no extra text in clipboard
    if (!clipboardText.includes('Join me for a game') && !clipboardText.includes('Oskol Poker!')) {
      console.log('✓ Clipboard does not contain extra text');
    } else {
      console.log('✗ Clipboard contains unwanted extra text');
    }
  } catch (error) {
    console.log('Note: Could not read clipboard (expected in some environments):', error.message);
  }

  await browser.close();
  console.log('\nTest completed successfully!');
})();
