#!/bin/bash
#
# Elixir/Phoenix Setup Script for Claude Code Web
#
# This script sets up Erlang and Elixir in Claude Code Web environment,
# handling common issues like SSL certificates and network restrictions.
#
# Usage:
#   ./scripts/setup-elixir-web.sh
#
# Or with custom versions:
#   ERLANG_VERSION=27.1.2 ELIXIR_VERSION=1.17.3 ./scripts/setup-elixir-web.sh

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default versions (can be overridden by environment variables)
ERLANG_VERSION="${ERLANG_VERSION:-27.1.2}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.17.3}"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Step 1: Install asdf if not already installed
install_asdf() {
    log_info "Checking for asdf installation..."

    if [ -f "$HOME/.asdf/asdf.sh" ]; then
        log_success "asdf already installed"
        return 0
    fi

    log_info "Installing asdf version manager..."
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1

    if [ $? -eq 0 ]; then
        log_success "asdf installed successfully"
    else
        log_error "Failed to install asdf"
        exit 1
    fi
}

# Step 2: Setup asdf in current shell
setup_asdf() {
    log_info "Loading asdf into current shell..."
    . "$HOME/.asdf/asdf.sh"

    # Set up SSL certificate path for Hex.pm (CRITICAL for Claude Code Web)
    export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt

    # Set UTF-8 encoding for Elixir
    export ELIXIR_ERL_OPTIONS="+fnu"
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8

    log_success "asdf loaded and environment configured"
}

# Step 3: Add asdf plugins
add_asdf_plugins() {
    log_info "Adding asdf plugins..."

    if asdf plugin list | grep -q "erlang"; then
        log_info "Erlang plugin already added"
    else
        asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
        log_success "Erlang plugin added"
    fi

    if asdf plugin list | grep -q "elixir"; then
        log_info "Elixir plugin already added"
    else
        asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
        log_success "Elixir plugin added"
    fi
}

# Step 4: Install Erlang
install_erlang() {
    log_info "Checking Erlang installation..."

    if asdf list erlang 2>/dev/null | grep -q "$ERLANG_VERSION"; then
        log_success "Erlang $ERLANG_VERSION already installed"
        return 0
    fi

    log_info "Installing Erlang $ERLANG_VERSION (this may take 10-15 minutes)..."
    log_warning "You may see warnings about missing odbc/wx libraries - these are optional"

    if asdf install erlang "$ERLANG_VERSION"; then
        log_success "Erlang $ERLANG_VERSION installed successfully"
    else
        log_error "Failed to install Erlang"
        log_info "Tip: Check ~/.asdf/plugins/erlang/kerl-home/builds/asdf_$ERLANG_VERSION/otp_build_$ERLANG_VERSION.log for details"
        exit 1
    fi
}

# Step 5: Install Elixir
install_elixir() {
    log_info "Checking Elixir installation..."

    if asdf list elixir 2>/dev/null | grep -q "$ELIXIR_VERSION"; then
        log_success "Elixir $ELIXIR_VERSION already installed"
        return 0
    fi

    log_info "Installing Elixir $ELIXIR_VERSION..."
    log_info "Attempting to install from source (Hex.pm may be blocked)..."

    # Try to install Elixir from git source (more reliable in restricted environments)
    if asdf install elixir "ref:v$ELIXIR_VERSION"; then
        log_success "Elixir $ELIXIR_VERSION installed from source"
        asdf global elixir "ref-v$ELIXIR_VERSION"
    else
        log_warning "Source installation failed, trying to build from GitHub..."

        # Fallback: Clone and build Elixir manually
        cd /tmp
        if [ -d "elixir-$ELIXIR_VERSION" ]; then
            rm -rf "elixir-$ELIXIR_VERSION"
        fi

        git clone --depth 1 --branch "v$ELIXIR_VERSION" https://github.com/elixir-lang/elixir.git "elixir-$ELIXIR_VERSION"
        cd "elixir-$ELIXIR_VERSION"

        # Set Erlang global so Elixir can build
        asdf global erlang "$ERLANG_VERSION"
        asdf reshim

        make clean compile

        # Install to asdf directory
        mkdir -p "$HOME/.asdf/installs/elixir/$ELIXIR_VERSION"
        cp -r /tmp/elixir-$ELIXIR_VERSION/* "$HOME/.asdf/installs/elixir/$ELIXIR_VERSION/"

        cd -
        log_success "Elixir $ELIXIR_VERSION built and installed manually"
    fi
}

# Step 6: Set global versions
set_global_versions() {
    log_info "Setting global versions..."

    asdf global erlang "$ERLANG_VERSION"
    asdf global elixir "$ELIXIR_VERSION" 2>/dev/null || asdf global elixir "ref-v$ELIXIR_VERSION" 2>/dev/null || asdf global elixir "$ELIXIR_VERSION"
    asdf reshim

    log_success "Global versions set"
}

# Step 7: Install Hex and Rebar
install_hex_rebar() {
    log_info "Installing Hex and Rebar..."

    # Install Hex from GitHub (more reliable than Hex.pm in restricted environments)
    log_info "Installing Hex package manager..."
    if mix archive.install github hexpm/hex branch latest --force; then
        log_success "Hex installed successfully"
    else
        log_warning "Hex installation had issues, but may still work"
    fi

    # Rebar3 installation often fails in restricted environments, but it's not always needed
    log_info "Attempting to install Rebar3..."
    if mix local.rebar --force 2>/dev/null; then
        log_success "Rebar3 installed successfully"
    else
        log_warning "Rebar3 installation failed, but it may not be needed for Phoenix"
        log_info "If you encounter rebar3 errors, you can install it manually"
    fi
}

# Step 8: Verify installation
verify_installation() {
    log_info "Verifying installation..."

    if command_exists elixir; then
        INSTALLED_ELIXIR=$(elixir --version | grep "Elixir" | head -n1)
        log_success "Elixir is available: $INSTALLED_ELIXIR"
    else
        log_error "Elixir command not found"
        exit 1
    fi

    if command_exists mix; then
        log_success "Mix build tool is available"
    else
        log_error "Mix command not found"
        exit 1
    fi
}

# Step 9: Install project dependencies
install_dependencies() {
    log_info "Installing project dependencies..."

    if [ ! -f "mix.exs" ]; then
        log_warning "No mix.exs found - skipping dependency installation"
        return 0
    fi

    log_info "Running mix deps.get (network restrictions may cause warnings)..."
    if mix deps.get; then
        log_success "Dependencies installed"
    else
        log_warning "Some dependencies failed to download, but cached versions may work"
    fi
}

# Step 10: Compile project
compile_project() {
    log_info "Compiling project..."

    if [ ! -f "mix.exs" ]; then
        log_warning "No mix.exs found - skipping compilation"
        return 0
    fi

    if mix compile; then
        log_success "Project compiled successfully"
    else
        log_error "Compilation failed"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    log_info "=========================================="
    log_info "Elixir/Phoenix Setup for Claude Code Web"
    log_info "=========================================="
    echo ""
    log_info "Target versions:"
    log_info "  Erlang: $ERLANG_VERSION"
    log_info "  Elixir: $ELIXIR_VERSION"
    echo ""

    install_asdf
    setup_asdf
    add_asdf_plugins
    install_erlang
    install_elixir
    set_global_versions
    install_hex_rebar
    verify_installation
    install_dependencies
    compile_project

    echo ""
    log_success "=========================================="
    log_success "Setup completed successfully!"
    log_success "=========================================="
    echo ""
    log_info "Next steps:"
    log_info "  1. Start Phoenix server: mix phx.server"
    log_info "  2. Visit: http://localhost:4000"
    echo ""
    log_info "For future sessions, run:"
    log_info "  source scripts/env-elixir.sh"
    echo ""
}

# Run main function
main
