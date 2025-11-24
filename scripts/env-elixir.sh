#!/bin/bash
#
# Environment Setup Script for Elixir/Phoenix
#
# Source this script to load asdf and set up environment variables
# for working with Elixir/Phoenix in Claude Code Web.
#
# Usage:
#   source scripts/env-elixir.sh
#   # or
#   . scripts/env-elixir.sh

# Load asdf
if [ -f "$HOME/.asdf/asdf.sh" ]; then
    . "$HOME/.asdf/asdf.sh"
else
    echo "ERROR: asdf not found. Run scripts/setup-elixir-web.sh first"
    return 1
fi

# Set critical environment variables for Hex.pm
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt

# Set UTF-8 encoding for Elixir
export ELIXIR_ERL_OPTIONS="+fnu"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

echo "✓ Elixir environment loaded"
echo "  Erlang: $(asdf current erlang 2>/dev/null | awk '{print $2}')"
echo "  Elixir: $(asdf current elixir 2>/dev/null | awk '{print $2}')"
echo ""
echo "Common commands:"
echo "  mix phx.server    # Start Phoenix server"
echo "  mix test          # Run tests"
echo "  mix compile       # Compile project"
