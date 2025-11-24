---
name: playwright-testing-claude-code-web
description: Use Playwright MCP for UI testing in Claude Code Web. Capture screenshots and share them via git. Use when testing web UIs in Claude Code Web. (project, gitignored)
---

# Playwright Testing in Claude Code Web

Navigate and test UIs with Playwright in headless environment. User can't access localhost, so Claude explores the app and shares screenshots via git.

## Playwright Config (One-time setup)

Create `playwright.config.js` if it doesn't exist:

```javascript
module.exports = {
  use: {
    headless: true,
    launchOptions: {
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
    }
  }
};
```

## Workflow: Navigate and Capture

1. **Write a test to navigate and capture screenshots:**

```bash
cat > .explore-temp.spec.js << 'EOF'
const { test } = require('@playwright/test');

test('explore app', async ({ page }) => {
  // Navigate to homepage
  await page.goto('http://localhost:4000');
  await page.waitForTimeout(1000);
  await page.screenshot({ path: 'screenshots/01-homepage.png', fullPage: true });

  // Click button, navigate to next page
  await page.click('text="Start New Game"');
  await page.waitForTimeout(1000);
  await page.screenshot({ path: 'screenshots/02-game-page.png', fullPage: true });

  // Continue exploring...
  // await page.fill('input[name="username"]', 'test');
  // await page.click('button[type="submit"]');
  // await page.screenshot({ path: 'screenshots/03-next-state.png', fullPage: true });
});
EOF
```

2. **Run with xvfb (fake framebuffer for headless browser):**

```bash
mkdir -p screenshots docs/screenshots
xvfb-run npx -y playwright test .explore-temp.spec.js --config=playwright.config.js
```

3. **View screenshots locally to see what happened:**

```bash
ls -lh screenshots/
# Claude can read these with Read tool to see the UI
```

4. **Share specific screenshots with user via git:**

```bash
# Copy interesting screenshots to docs/ for git sharing
cp screenshots/02-game-page.png docs/screenshots/game-$(date +%Y%m%d-%H%M%S).png

# Commit and push
git add docs/screenshots/
git commit -m "Add screenshot: game page exploration"
git push

# Generate URL for user
REPO_URL=$(git remote get-url origin | sed 's|http://.*@127.0.0.1:[0-9]*/git/||' | sed 's/\.git$//')
BRANCH=$(git branch --show-current)
echo "https://github.com/${REPO_URL}/raw/${BRANCH}/docs/screenshots/game-*.png"
```

5. **Clean up temp files:**

```bash
rm -f .explore-temp.spec.js
```

## Key Points

- **Write interactive tests** to navigate the app, not just capture homepage
- **Use xvfb-run** for headless browser (required in Claude Code Web)
- **Capture screenshots at interesting states** to verify UI behavior
- **Read screenshots** with Read tool to see what's rendered
- **Share via git** by copying to `docs/screenshots/` and pushing
- **No package.json needed** - use `npx -y` directly
- **Temp test files** (.explore-temp.spec.js) should be in project root and cleaned up after

## Cleanup Before Merge

```bash
git rm -r docs/screenshots/
git commit -m "Clean up test screenshots"
```
