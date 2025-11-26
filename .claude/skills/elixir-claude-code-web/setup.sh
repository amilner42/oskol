#!/bin/bash
#
# Elixir/Phoenix Setup Script for Claude Code Web
#
# This script sets up Erlang, Elixir, and development tools
# for working with Phoenix projects in Claude Code Web.
#
# Usage:
#   ./scripts/setup-elixir-web.sh

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

    # Add to shell profile for persistence
    if ! grep -q "asdf.sh" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" << 'EOF'

# Elixir/asdf setup
. "$HOME/.asdf/asdf.sh"
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
export ELIXIR_ERL_OPTIONS="+fnu"
EOF
        log_info "Added asdf and environment to ~/.bashrc"
    fi

    log_success "asdf installed successfully"
}

# Step 2: Setup asdf and environment in current shell
setup_asdf() {
    log_info "Loading asdf into current shell..."
    . "$HOME/.asdf/asdf.sh"

    # Set SSL certificates for Hex.pm (required for proxy environments)
    export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt

    # Set UTF-8 encoding for Elixir
    export ELIXIR_ERL_OPTIONS="+fnu"
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8

    log_success "asdf and environment loaded"
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

# Step 4: Install Erlang & Elixir from .tool-versions
install_languages() {
    log_info "Installing Erlang & Elixir from .tool-versions..."
    log_warning "Erlang compilation may take 10-15 minutes"

    asdf install

    asdf reshim
    log_success "Erlang & Elixir installed"
}

# Step 5: Install Hex and Rebar
install_hex_rebar() {
    log_info "Installing Hex and Rebar..."

    mix local.hex --force
    log_success "Hex installed"

    mix local.rebar --force
    log_success "Rebar installed"
}

# Step 6: Verify installation
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

# Step 7: Install project dependencies
install_dependencies() {
    log_info "Installing project dependencies..."

    if [ ! -f "mix.exs" ]; then
        log_warning "No mix.exs found - skipping dependency installation"
        return 0
    fi

    mix deps.get
    log_success "Dependencies installed"
}

# Step 8: Compile project
compile_project() {
    log_info "Compiling project..."

    if [ ! -f "mix.exs" ]; then
        log_warning "No mix.exs found - skipping compilation"
        return 0
    fi

    mix compile
    log_success "Project compiled"
}

# Step 9: Setup Phoenix assets
setup_assets() {
    log_info "Setting up Phoenix assets..."

    if [ ! -f "mix.exs" ]; then
        log_warning "No mix.exs found - skipping asset setup"
        return 0
    fi

    if mix help assets.setup >/dev/null 2>&1; then
        mix assets.setup
        mix assets.build
        log_success "Assets set up"
    else
        log_info "No assets.setup task found - skipping"
    fi
}

# Step 10: Install Playwright locally via package.json
install_playwright() {
    log_info "Installing Playwright locally..."

    if [ ! -f "package.json" ]; then
        log_warning "No package.json found - skipping Playwright installation"
        return 0
    fi

    if command_exists npm; then
        npm install
        npx playwright install chromium
        log_success "Playwright installed locally from package.json"
    else
        log_warning "npm not found - skipping Playwright installation"
    fi
}

# Main execution
main() {
    echo ""
    log_info "=========================================="
    log_info "Elixir/Phoenix Setup for Claude Code Web"
    log_info "=========================================="
    echo ""

    install_asdf
    setup_asdf
    add_asdf_plugins
    install_languages
    install_hex_rebar
    verify_installation
    install_dependencies
    compile_project
    setup_assets
    install_playwright

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
    log_info "  . ~/.asdf/asdf.sh && export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt"
    echo ""
}

# Run main function
main
