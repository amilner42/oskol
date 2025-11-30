const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage();

  // Navigate to the landing page with hard reload
  await page.goto('http://localhost:4000', { waitUntil: 'networkidle' });

  // Force a hard reload to get latest code
  await page.reload({ waitUntil: 'networkidle' });

  // Wait for the page to load and animations
  await page.waitForTimeout(2000);

  // Screenshot 1: Full landing page showing "Testing Poker warfare"
  await page.screenshot({
    path: 'playwright/screenshots/test-53-update-landing-page/01-landing-page-with-testing-poker-warfare.png',
    fullPage: true
  });

  // Screenshot 2: Get the actual text content to verify
  const subtitleText = await page.evaluate(() => {
    const subtitle = document.querySelector('.text-base-content\\/50.text-sm.tracking-widest.uppercase');
    return subtitle ? subtitle.textContent.trim() : 'NOT FOUND';
  });
  console.log('Subtitle text content:', subtitleText);

  // Screenshot 3: Close-up of the logo and subtitle area with clip
  const logoElement = await page.$('.animate-logo');
  if (logoElement) {
    const boundingBox = await logoElement.boundingBox();
    await page.screenshot({
      path: 'playwright/screenshots/test-53-update-landing-page/02-logo-and-subtitle-closeup.png',
      clip: {
        x: Math.max(0, boundingBox.x - 50),
        y: Math.max(0, boundingBox.y - 20),
        width: boundingBox.width + 100,
        height: boundingBox.height + 40
      }
    });
  }

  await browser.close();
})();
