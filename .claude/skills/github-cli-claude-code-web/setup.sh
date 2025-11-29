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

# Step 2: Install GitHub CLI
install_gh() {
    log_info "Checking for gh installation..."

    if command_exists gh; then
        log_success "gh already installed: $(gh --version | head -n1)"
        return 0
    fi

    log_info "Installing GitHub CLI..."

    # Add GitHub CLI repository
    (type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
        && sudo mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && sudo apt update \
        && sudo apt install gh -y

    log_success "GitHub CLI installed: $(gh --version | head -n1)"
}

# Step 3: Configure authentication
configure_auth() {
    log_info "Configuring GitHub CLI authentication..."

    # GH_TOKEN should already be set in the environment
    log_success "Authentication configured (using GH_TOKEN from environment)"
}

# Step 4: Verify authentication
verify_auth() {
    log_info "Verifying GitHub authentication..."

    if gh auth status 2>&1 | grep -q "Logged in"; then
        log_success "GitHub authentication verified"
        gh auth status
    else
        log_warning "Authentication check returned unexpected status"
        gh auth status || true
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
    log_info "GH_TOKEN is set automatically in Claude Code Web"
    echo ""
}

# Run main function
main
