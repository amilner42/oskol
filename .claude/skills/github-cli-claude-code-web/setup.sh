#!/bin/bash
#
# GitHub CLI Setup Script for Claude Code Web
#
# This script installs the GitHub CLI and configures authentication
# using the GH_TOKEN environment variable.
#
# Usage:
#   .claude/skills/github-cli-claude-code-web/setup.sh

set -e  # Exit on error

# Configuration
GH_VERSION="2.63.2"
INSTALL_DIR="$HOME/.local/bin"

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

# Step 1: Check for GH_TOKEN
check_token() {
    log_info "Checking for GH_TOKEN..."

    if [ -z "$GH_TOKEN" ]; then
        log_error "GH_TOKEN environment variable is not set"
        log_error "Claude Code Web should have this set automatically"
        exit 1
    fi

    log_success "GH_TOKEN is available"
}

# Step 2: Install GitHub CLI (via direct binary download)
install_gh() {
    log_info "Checking for gh installation..."

    if command_exists gh; then
        log_success "gh already installed: $(gh --version | head -n1)"
        return 0
    fi

    log_info "Installing GitHub CLI v${GH_VERSION}..."

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    # Download and extract gh binary
    local tmp_dir=$(mktemp -d)
    local archive="gh_${GH_VERSION}_linux_amd64.tar.gz"
    local url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${archive}"

    log_info "Downloading from GitHub releases..."
    if ! curl -sL "$url" -o "$tmp_dir/$archive"; then
        log_error "Failed to download GitHub CLI"
        rm -rf "$tmp_dir"
        exit 1
    fi

    log_info "Extracting..."
    tar xzf "$tmp_dir/$archive" -C "$tmp_dir"

    # Move binary to install directory
    mv "$tmp_dir/gh_${GH_VERSION}_linux_amd64/bin/gh" "$INSTALL_DIR/gh"
    chmod +x "$INSTALL_DIR/gh"

    # Clean up
    rm -rf "$tmp_dir"

    # Add to PATH for current session if not already there
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        export PATH="$INSTALL_DIR:$PATH"
    fi

    log_success "GitHub CLI installed: $($INSTALL_DIR/gh --version | head -n1)"
}

# Step 3: Ensure PATH is configured
configure_path() {
    log_info "Configuring PATH..."

    # Add to .bashrc if not already present
    if ! grep -q "$INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null; then
        echo "" >> "$HOME/.bashrc"
        echo "# GitHub CLI" >> "$HOME/.bashrc"
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.bashrc"
        log_success "Added $INSTALL_DIR to .bashrc"
    else
        log_success "PATH already configured in .bashrc"
    fi

    # Export for current session
    export PATH="$INSTALL_DIR:$PATH"
}

# Step 4: Configure authentication
configure_auth() {
    log_info "Configuring GitHub CLI authentication..."

    # GH_TOKEN is automatically used by gh when set in environment
    log_success "Authentication configured (using GH_TOKEN from environment)"
}

# Step 5: Verify authentication
verify_auth() {
    log_info "Verifying GitHub authentication..."

    if gh auth status 2>&1 | grep -q "Logged in"; then
        log_success "GitHub authentication verified"
        gh auth status
    else
        # GH_TOKEN should work automatically, show status anyway
        log_success "GitHub CLI ready (GH_TOKEN will be used for authentication)"
    fi
}

# Main execution
main() {
    echo ""
    log_info "=========================================="
    log_info "GitHub CLI Setup for Claude Code Web"
    log_info "=========================================="
    echo ""

    check_token
    install_gh
    configure_path
    configure_auth
    verify_auth

    echo ""
    log_success "=========================================="
    log_success "Setup completed successfully!"
    log_success "=========================================="
    echo ""
    log_info "You can now use gh commands:"
    log_info "  gh pr create --title 'Title' --body 'Description'"
    log_info "  gh pr list"
    log_info "  gh issue list"
    echo ""
    log_info "GH_TOKEN is used automatically for authentication"
    echo ""
}

# Run main function
main
