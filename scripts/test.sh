#!/bin/bash
set -e

# CC Status Bar - Test Script
# This script is used by both pre-push hook and GitHub Actions

echo "=== Swift Tests ==="
swift test

echo ""
echo "=== TypeScript Build Check ==="
cd StreamDeckPlugin/com.ccstatusbar.sdPlugin
npx tsc --noEmit

echo ""
echo "=== All tests passed ==="
