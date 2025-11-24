# Setup Scripts for Claude Code Web

This directory contains scripts to help set up and run the Oskol project in Claude Code Web environment.

## Scripts

### `setup-elixir-web.sh`

**Purpose**: Automated setup of Erlang and Elixir in Claude Code Web environment.

**What it does**:
- Installs asdf version manager (if not present)
- Installs Erlang and Elixir
- Configures SSL certificates for Hex.pm
- Installs Hex package manager and Rebar3
- Installs project dependencies
- Compiles the project

**Usage**:
```bash
# Run the setup script
chmod +x scripts/setup-elixir-web.sh
./scripts/setup-elixir-web.sh
```

**Custom versions**:
```bash
# Install specific versions
ERLANG_VERSION=27.1.2 ELIXIR_VERSION=1.17.3 ./scripts/setup-elixir-web.sh
```

**Expected output**:
- Setup takes 10-15 minutes (mostly Erlang compilation)
- You may see warnings about missing wx/odbc libraries (these are optional)
- Script will show green ✓ for each successful step

### `env-elixir.sh`

**Purpose**: Quick environment setup for existing installations.

**What it does**:
- Loads asdf into your shell
- Sets required environment variables
- Shows current Erlang/Elixir versions

**Usage**:
```bash
# Source this script (note the leading dot)
source scripts/env-elixir.sh
```

**When to use**:
- Start of each new Claude Code session
- After the initial setup is complete
- When you get "command not found" errors for elixir/mix

## Common Issues and Solutions

### Issue: "httpc request failed with: {:bad_status_code, 403}"

**Cause**: Hex.pm access is restricted in Claude Code Web environment.

**Solution**: The scripts automatically work around this by:
- Installing Hex from GitHub instead of Hex.pm
- Using cached dependencies when possible
- Building Elixir from source if needed

**Manual fix** (if scripts fail):
```bash
source scripts/env-elixir.sh
mix archive.install github hexpm/hex branch latest --force
```

### Issue: "Unknown package X in lockfile"

**Cause**: Dependencies can't be fetched from Hex.pm registry.

**Solution**: Use existing mix.lock and cached dependencies:
```bash
# Remove problematic entries
rm -rf _build deps
source scripts/env-elixir.sh
mix deps.get
```

### Issue: "warning: the VM is running with native name encoding of latin1"

**Cause**: UTF-8 encoding not set.

**Solution**: The scripts automatically set this, but if you see it:
```bash
export ELIXIR_ERL_OPTIONS="+fnu"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
```

### Issue: Erlang compilation fails

**Cause**: Missing build dependencies or insufficient resources.

**Solution**:
1. Check the build log:
   ```bash
   cat ~/.asdf/plugins/erlang/kerl-home/builds/asdf_*/otp_build_*.log
   ```
2. Try with a different Erlang version:
   ```bash
   ERLANG_VERSION=26.2.5 ./scripts/setup-elixir-web.sh
   ```

### Issue: Elixir build fails

**Cause**: Erlang not set as global version.

**Solution**:
```bash
source scripts/env-elixir.sh
asdf global erlang 27.1.2
asdf reshim
# Then retry Elixir installation
```

## Quick Start Guide

### First Time Setup (Fresh Environment)

```bash
# 1. Clone the repository (if not already done)
cd /home/user/oskol

# 2. Run the setup script
chmod +x scripts/setup-elixir-web.sh
./scripts/setup-elixir-web.sh

# 3. Start the Phoenix server
mix phx.server

# 4. Visit http://localhost:4000
```

### Subsequent Sessions

```bash
# 1. Load the environment
source scripts/env-elixir.sh

# 2. Start the Phoenix server
mix phx.server
```

## Playwright Testing

After setup is complete, you can run Playwright tests:

```bash
# Terminal 1: Start Phoenix server
source scripts/env-elixir.sh
mix phx.server

# Terminal 2: Run Playwright test
cd playwright/test-rank-increase-action
node test.js
```

Screenshots will be saved to `playwright/screenshots/test-rank-increase-action/`.

## Environment Variables Reference

These are automatically set by the scripts:

| Variable | Purpose | Value |
|----------|---------|-------|
| `HEX_CACERTS_PATH` | SSL certificates for Hex.pm | `/etc/ssl/certs/ca-certificates.crt` |
| `ELIXIR_ERL_OPTIONS` | UTF-8 encoding for Erlang VM | `+fnu` |
| `LANG` | System locale | `C.UTF-8` |
| `LC_ALL` | All locale categories | `C.UTF-8` |

## Manual Installation (If Scripts Fail)

If automated scripts fail, you can follow these steps manually:

```bash
# 1. Install asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
. ~/.asdf/asdf.sh

# 2. Add plugins
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git

# 3. Install Erlang
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
asdf install erlang 27.1.2

# 4. Install Elixir from source
asdf global erlang 27.1.2
cd /tmp
git clone --depth 1 --branch v1.17.3 https://github.com/elixir-lang/elixir.git
cd elixir
make clean compile
mkdir -p ~/.asdf/installs/elixir/1.17.3
cp -r /tmp/elixir/* ~/.asdf/installs/elixir/1.17.3/

# 5. Set global versions
asdf global erlang 27.1.2
asdf global elixir 1.17.3
asdf reshim

# 6. Install Hex
export ELIXIR_ERL_OPTIONS="+fnu"
mix archive.install github hexpm/hex branch latest --force

# 7. Install dependencies
cd /home/user/oskol
mix deps.get
mix compile
```

## Troubleshooting Tips

1. **Always source env-elixir.sh** at the start of each session
2. **Check asdf versions**: `asdf current`
3. **Verify paths**: `which elixir` and `which mix`
4. **Clean and rebuild**: `rm -rf _build deps && mix deps.get && mix compile`
5. **Check logs**: Look in `~/.asdf/plugins/` for detailed error logs

## Contributing

If you encounter issues not covered here or have improvements to the scripts, please:
1. Document the issue and solution
2. Update the scripts if applicable
3. Submit a PR with the improvements
