#!/bin/bash
# Setup git hooks for CC Status Bar development

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

echo "Setting up git hooks..."

# Create symlink for pre-push hook
ln -sf "../../scripts/hooks/pre-push" "$HOOKS_DIR/pre-push"
chmod +x "$HOOKS_DIR/pre-push"

echo "pre-push hook enabled"
echo ""
echo "Done! Tests will run before each push."
