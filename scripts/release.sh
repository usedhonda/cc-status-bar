#!/bin/bash
set -e

# CC Status Bar Release Script
# Usage:
#   ./scripts/release.sh              # Full release (Developer ID signing + notarization)
#   ./scripts/release.sh --no-notarize # Self-signed release (no Apple Developer Program required)

# === Configuration ===
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Yuzuru Honda (XXXXXXXXXX)}"
KEYCHAIN_PROFILE="ccstatusbar-notary"
SELF_SIGN_ID="CCStatusBar Dev"
NO_NOTARIZE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-notarize)
      NO_NOTARIZE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./scripts/release.sh [--no-notarize]"
      exit 1
      ;;
  esac
done

echo "=== CC Status Bar Release Build ==="

if $NO_NOTARIZE; then
  echo "Mode: Self-signed (no notarization)"
else
  echo "Mode: Developer ID + Notarization"
fi

# Build
echo "[1/5] Building release..."
swift build -c release

# Copy binary to app bundle
echo "[2/5] Copying binary..."
cp .build/release/CCStatusBar CCStatusBar.app/Contents/MacOS/

# Sign
echo "[3/5] Code signing..."
if $NO_NOTARIZE; then
  # Self-signed for distribution without Developer Program
  codesign --force --deep --sign "$SELF_SIGN_ID" CCStatusBar.app
  echo "Signed with self-signed certificate: $SELF_SIGN_ID"
else
  # Developer ID signing with hardened runtime for notarization
  codesign --force --deep --options runtime \
    --sign "$DEVELOPER_ID" \
    CCStatusBar.app
fi

# Verify signature
codesign --verify --verbose CCStatusBar.app

# Create ZIP
echo "[4/5] Creating ZIP..."
rm -f CCStatusBar.app.zip
ditto -c -k --keepParent CCStatusBar.app CCStatusBar.app.zip

if $NO_NOTARIZE; then
  echo "[5/5] Skipping notarization (--no-notarize)"
else
  # Notarize
  echo "[5/5] Notarizing..."
  xcrun notarytool submit CCStatusBar.app.zip \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

  # Staple ticket to app
  echo "Stapling..."
  xcrun stapler staple CCStatusBar.app

  # Recreate ZIP with stapled app
  rm -f CCStatusBar.app.zip
  ditto -c -k --keepParent CCStatusBar.app CCStatusBar.app.zip
fi

echo ""
echo "=== Done! ==="
echo "CCStatusBar.app.zip is ready for distribution"
echo ""

if $NO_NOTARIZE; then
  echo "Note: This build is self-signed. Users will see Gatekeeper warning."
  echo "See README.md for installation instructions."
else
  echo "To create a new GitHub release:"
  echo "  gh release create v1.0.0 CCStatusBar.app.zip --title 'v1.0.0' --notes 'Initial release'"
fi
