#!/bin/bash
set -e

# CC Status Bar Release Script
# Usage: ./scripts/release.sh

# === Configuration ===
# Update DEVELOPER_ID after certificate is ready
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Yuzuru Honda (XXXXXXXXXX)}"
KEYCHAIN_PROFILE="ccstatusbar-notary"

echo "=== CC Status Bar Release Build ==="

# Build
echo "[1/5] Building release..."
swift build -c release

# Copy binary to app bundle
echo "[2/5] Copying binary..."
cp .build/release/CCStatusBar CCStatusBar.app/Contents/MacOS/

# Sign with Developer ID + hardened runtime
echo "[3/5] Code signing..."
codesign --force --deep --options runtime \
  --sign "$DEVELOPER_ID" \
  CCStatusBar.app

# Verify signature
codesign --verify --verbose CCStatusBar.app

# Create ZIP for notarization
echo "[4/5] Notarizing..."
rm -f CCStatusBar.app.zip
ditto -c -k --keepParent CCStatusBar.app CCStatusBar.app.zip

xcrun notarytool submit CCStatusBar.app.zip \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

# Staple ticket to app
echo "[5/5] Stapling..."
xcrun stapler staple CCStatusBar.app

echo ""
echo "=== Done! ==="
echo "CCStatusBar.app is ready for distribution"
echo ""
echo "To create a new GitHub release:"
echo "  gh release create v1.0.0 CCStatusBar.app.zip --title 'v1.0.0' --notes 'Initial release'"
