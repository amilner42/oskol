# Complete a GitHub Issue

Complete a GitHub issue end-to-end, including setup, implementation, and visual verification.

## Issue to work on: $ARGUMENTS

## Workflow

### Step 1: Setup GitHub CLI

Run the GitHub CLI skill to ensure `gh` is available:

```bash
.claude/skills/github-cli-claude-code-web/setup.sh
```

Then fetch the issue details:

```bash
gh issue view <issue-number>
```

Read and understand the issue requirements before proceeding.

### Step 2: Setup Elixir Environment

Run the Elixir skill to ensure the development environment is ready:

```bash
.claude/skills/elixir-claude-code-web/setup.sh
```

Or if already set up in a previous session:

```bash
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
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
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server &

# Run the verification script
node playwright/test-<issue-slug>/test.js
```

### Step 5: Review Screenshots

Use the Read tool to view the captured screenshots and verify the implementation looks correct.

### Step 6: Summary

After completing all steps, provide:
- Summary of changes made
- List of files modified
- Screenshot review confirming the fix
- Any notes or follow-up items

## Notes

- If any step fails, troubleshoot using the relevant skill documentation
- Commit changes when implementation is complete and verified
- Reference the issue number in commit messages (e.g., "Fix #123: description")
