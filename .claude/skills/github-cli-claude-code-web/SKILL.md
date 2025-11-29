---
name: github-cli-claude-code-web
description: Set up GitHub CLI (gh) in Claude Code Web for PR creation, issue management, and repo operations. Use when working with GitHub from Claude Code Web. (project, gitignored)
---

# GitHub CLI Setup for Claude Code Web

Install and configure the GitHub CLI (`gh`) to work with your repositories.

## Full Setup (First Time)

Run the setup script to install gh:

```bash
.claude/skills/github-cli-claude-code-web/setup.sh
```

This installs:
- GitHub CLI (`gh`) via apt
- Configures authentication using existing GH_TOKEN

## Quick Start (After Setup)

For subsequent sessions where gh is already installed:

```bash
gh auth status
```

## Common Commands

### Pull Requests
```bash
gh pr create --title "Title" --body "Description"
gh pr list
gh pr view 123
gh pr checkout 123
gh pr merge 123
```

### Issues
```bash
gh issue create --title "Title" --body "Description"
gh issue list
gh issue view 123
gh issue close 123
```

### Repository
```bash
gh repo view
gh repo clone owner/repo
```

## Troubleshooting

### Authentication failed
```bash
# Ensure GH_TOKEN is set
echo $GH_TOKEN
gh auth status
```

### gh command not found
```bash
# Re-run setup
.claude/skills/github-cli-claude-code-web/setup.sh
```
