---
name: elixir-claude-code-web
description: Set up Elixir/Phoenix development in Claude Code Web with asdf, npm, and Playwright. Use when working with Elixir/Phoenix projects in Claude Code Web environment. (project, gitignored)
---

# Elixir Setup for Claude Code Web

Complete setup for Elixir/Phoenix development with testing tools.

## Full Setup (First Time)

Run the setup script to install everything:

```bash
.claude/skills/elixir-claude-code-web/setup.sh
```

This installs:
- asdf version manager
- Erlang & Elixir (from .tool-versions)
- Hex and Rebar
- Project dependencies
- Phoenix assets
- Playwright for testing

## Quick Start (After Setup)

For subsequent sessions where asdf is already installed:

```bash
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server
```

Server runs at http://localhost:4000

## Running Tests

```bash
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix test
```

## Running Playwright Tests

```bash
# Start server in background
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
mix phx.server &

# Run playwright test
node playwright/<test-folder>/test.js
```

## Troubleshooting

### SSL/TLS Unknown CA errors
```bash
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
```

### asdf not found
```bash
. ~/.asdf/asdf.sh
```

### mix/elixir not found after asdf install
```bash
asdf reshim elixir
```

### Playwright browser not found
```bash
npx playwright install chromium
```

### Dependencies out of date
```bash
mix deps.get
mix compile
```
