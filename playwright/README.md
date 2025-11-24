# Playwright Tests

Automated browser tests for the Oskol poker roguelike game.

## Structure

```
playwright/
├── README.md                    # This file
├── screenshots/                 # Screenshots from test runs
│   └── test-suit-action-card/              # One folder per test
└── test-suit-action-card/                   # Full game flow test
    ├── README.md               # Test-specific documentation
    └── test.js                 # The test script
```

## Available Tests

### `test-suit-action-card/`
End-to-end test covering lobby → game → shop flow, including the suit-changing card feature.

**Run:** `node playwright/test-suit-action-card/test.js`

See `test-suit-action-card/README.md` for details.

## Running Tests

```bash
# Make sure server is running
mix phx.server

# Run a specific test (in another terminal)
node playwright/test-suit-action-card/test.js

# View screenshots
ls playwright/screenshots/test-suit-action-card/
```

## Screenshots

Screenshots are saved to `playwright/screenshots/<test-name>/`

## Adding New Tests

1. Create a new directory: `playwright/my-test/`
2. Add the test script: `playwright/my-test/test.js`
3. Add documentation: `playwright/my-test/README.md`
4. Update this README with a link to the new test
5. Make sure screenshots save to: `playwright/screenshots/my-test/`

## Test Template

```javascript
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
  const page = await context.newPage();

  try {
    log('Starting test...');

    await page.goto('http://localhost:4000');
    await sleep(1000);
    await page.screenshot({
      path: 'playwright/screenshots/my-test/01-homepage.png',
      fullPage: true
    });
    log('✓ Screenshot: 01-homepage.png');

    // Add your test steps here...

  } catch (error) {
    log(`ERROR: ${error.message}`);
    await page.screenshot({
      path: 'playwright/screenshots/my-test/ERROR.png',
      fullPage: true
    });
  } finally {
    await browser.close();
    log('Test complete!');
  }
}

main().catch(console.error);
```

## Best Practices

- **Use descriptive names** for tests and screenshots
- **Add timestamps** to logs for debugging
- **Save error screenshots** when tests fail
- **Document what each test verifies** in its README
- **Use sleep() appropriately** - LiveView needs time to update
- **Keep tests focused** - one test per feature/flow
