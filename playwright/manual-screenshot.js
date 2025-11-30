const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });

  await page.goto('http://localhost:4002');

  console.log('\n================================');
  console.log('Manual Screenshot Tool');
  console.log('================================');
  console.log('Navigate to the shop screen manually.');
  console.log('Press ENTER when ready to take screenshot...\n');

  await new Promise(resolve => {
    process.stdin.once('data', resolve);
  });

  await page.screenshot({
    path: 'current-shop-view.png',
    fullPage: true
  });

  console.log('✅ Screenshot saved to current-shop-view.png');
  console.log('Browser will stay open. Close when done.\n');

  // Keep browser open
  await new Promise(() => {});
})();
