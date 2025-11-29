# Complete a GitHub Issue

Complete a GitHub issue end-to-end, including setup, implementation, and visual verification.

## Issue to work on: $ARGUMENTS

## Workflow

### Step 1: Setup GitHub CLI

Run the GitHub CLI setup (idempotent - skips if already installed):

```bash
.claude/skills/github-cli-claude-code-web/setup.sh
```

Then fetch the issue details:

```bash
$HOME/.local/bin/gh issue view <issue-number> --repo amilner42/oskol
```

Read and understand the issue requirements before proceeding.

### Step 2: Setup Elixir Environment

Run the Elixir setup (idempotent - skips if already installed):

```bash
.claude/skills/elixir-claude-code-web/setup.sh
```

Verify with `mix compile` to ensure dependencies are ready.

### Step 3: Implement the Issue

- Read the relevant code files to understand the current implementation
- Make the necessary changes to complete the issue
- Run `mix compile` to check for compilation errors
- Run `mix test` to ensure tests pass

### Step 4: Create Playwright Verification Script

After implementing the changes, create a Playwright test to visually verify the work:

1. Create a new test folder: `playwright/test-<issue-slug>/`
2. Add a `test.js` script that:
   - Navigates to the relevant screens
   - Captures screenshots showing the changes
   - Saves to `playwright/screenshots/test-<issue-slug>/`
3. Add a `README.md` explaining what the test verifies

Reference the Playwright skill for patterns:
- See `.claude/skills/playwright-testing-claude-code-web/SKILL.md`
- See existing tests in `playwright/` for examples

Run the test:

```bash
# Start server in background
mix phx.server &

# Run the verification script
node playwright/test-<issue-slug>/test.js
```

### Step 5: Review Screenshots

Use the Read tool to view the captured screenshots and verify the implementation looks correct.

### Step 6: Commit and Create Pull Request

Once implementation is verified:

1. **Commit the changes:**
   ```bash
   git add -A
   git commit -m "Fix #<issue-number>: <description>"
   ```

2. **Push and create PR with screenshots:**
   ```bash
   git push -u origin HEAD
   ```

3. **Create the PR with screenshots:**

   Screenshots are already saved in `playwright/screenshots/test-<issue-slug>/` (matching the test folder name). Commit and push them, then reference in the PR:

   ```bash
   git add playwright/screenshots/test-<issue-slug>/
   git commit -m "Add screenshots for #<issue-number>"
   git push

   $HOME/.local/bin/gh pr create \
     --title "Fix #<issue-number>: <description>" \
     --body "## Summary
   <Brief description of changes>

   ## Screenshots
   ![Description](playwright/screenshots/test-<issue-slug>/01-screenshot.png)
   ![Description](playwright/screenshots/test-<issue-slug>/02-screenshot.png)

   Fixes #<issue-number>" \
     --repo amilner42/oskol
   ```

   **Folder structure:**
   ```
   playwright/
   ├── test-<issue-slug>/          # Test script
   │   └── test.js
   └── screenshots/
       └── test-<issue-slug>/      # Screenshots (same folder name!)
           ├── 01-screenshot.png
           └── 02-screenshot.png
   ```

**IMPORTANT**: Always include screenshots in the PR body using relative paths to the committed files!

### Step 7: Summary

After completing all steps, provide:
- Summary of changes made
- List of files modified
- Screenshot review confirming the fix
- Link to the created PR
- Any notes or follow-up items

## Notes

- If any step fails, troubleshoot using the relevant skill documentation
- Always include screenshots in PRs to show visual changes
- Reference the issue number in commit messages and PR title (e.g., "Fix #123: description")
