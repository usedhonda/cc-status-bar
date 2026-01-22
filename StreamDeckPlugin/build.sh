#!/bin/bash
# Build and package Stream Deck plugin
#
# Prerequisites:
#   npm install -g @elgato/cli
#
# Output:
#   com.ccstatusbar.streamDeckPlugin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/com.ccstatusbar.sdPlugin"

echo "=== Building Stream Deck Plugin ==="

# Step 1: Compile TypeScript
echo "[1/2] Compiling TypeScript..."
cd "$PLUGIN_DIR"
npx tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS --esModuleInterop

# Step 2: Package plugin
echo "[2/2] Packaging plugin..."
cd "$SCRIPT_DIR"
streamdeck pack com.ccstatusbar.sdPlugin

echo ""
echo "=== Build Complete ==="
echo "Output: $SCRIPT_DIR/com.ccstatusbar.streamDeckPlugin"
echo ""
echo "To install: Double-click the .streamDeckPlugin file"
