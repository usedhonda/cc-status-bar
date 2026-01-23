#!/bin/bash
# CC Status Bar Release Script
#
# Usage:
#   ./scripts/release.sh          # Build and notarize only
#   ./scripts/release.sh --publish # Build, notarize, and create GitHub release
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - Developer ID certificate
#   - npm install -g @elgato/cli (for Stream Deck plugin)
#   - gh CLI (for GitHub release)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="CCStatusBar"
DMG_PATH="/tmp/${APP_NAME}.dmg"
DMG_STAGING="/tmp/dmg-contents"

# Apple credentials (from .local/release.md)
APPLE_ID="honda@ofinventi.one"
TEAM_ID="F588423ZWS"
APP_PASSWORD="vyen-roli-fagw-lgmo"
SIGNING_ID="Developer ID Application: Yuzuru Honda (${TEAM_ID})"

cd "$PROJECT_DIR"

echo -e "${GREEN}=== CC Status Bar Release ===${NC}"
echo ""

# Get version from Info.plist
VERSION=$(plutil -extract CFBundleShortVersionString raw "${APP_NAME}.app/Contents/Info.plist")
echo -e "Version: ${YELLOW}${VERSION}${NC}"
echo ""

# Step 1: Run tests
echo -e "${GREEN}[1/8] Running tests...${NC}"
swift test --quiet
echo -e "${GREEN}Tests passed${NC}"
echo ""

# Step 2: Release build
echo -e "${GREEN}[2/8] Building release...${NC}"
swift build -c release --quiet
echo -e "${GREEN}Build complete${NC}"
echo ""

# Step 3: Copy to app bundle
echo -e "${GREEN}[3/8] Updating app bundle...${NC}"
cp .build/release/${APP_NAME} ${APP_NAME}.app/Contents/MacOS/
echo -e "${GREEN}App bundle updated${NC}"
echo ""

# Step 4: Sign app
echo -e "${GREEN}[4/8] Signing app...${NC}"
codesign --force --deep --options runtime --sign "${SIGNING_ID}" ${APP_NAME}.app
echo -e "${GREEN}App signed${NC}"
echo ""

# Step 5: Create DMG
echo -e "${GREEN}[5/8] Creating DMG...${NC}"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R ${APP_NAME}.app "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_PATH}"
codesign --force --sign "${SIGNING_ID}" "${DMG_PATH}"
echo -e "${GREEN}DMG created: ${DMG_PATH}${NC}"
echo ""

# Step 6: Notarize
echo -e "${GREEN}[6/8] Notarizing DMG (this may take a few minutes)...${NC}"
xcrun notarytool submit "${DMG_PATH}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${TEAM_ID}" \
  --password "${APP_PASSWORD}" \
  --wait
echo -e "${GREEN}Notarization complete${NC}"
echo ""

# Step 7: Staple
echo -e "${GREEN}[7/8] Stapling notarization...${NC}"
xcrun stapler staple "${DMG_PATH}"
echo -e "${GREEN}Stapling complete${NC}"
echo ""

# Step 8: Build Stream Deck plugin
echo -e "${GREEN}[8/8] Building Stream Deck plugin...${NC}"
cd StreamDeckPlugin/com.ccstatusbar.sdPlugin
npx tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS --esModuleInterop
cd ..
streamdeck pack com.ccstatusbar.sdPlugin -f
PLUGIN_PATH="${PROJECT_DIR}/StreamDeckPlugin/com.ccstatusbar.streamDeckPlugin"
cd "$PROJECT_DIR"
echo -e "${GREEN}Stream Deck plugin built: ${PLUGIN_PATH}${NC}"
echo ""

# Summary
echo -e "${GREEN}=== Build Complete ===${NC}"
echo ""
echo "Release artifacts:"
echo "  - ${DMG_PATH}"
echo "  - ${PLUGIN_PATH}"
echo ""

# Publish to GitHub if --publish flag is set
if [[ "$1" == "--publish" ]]; then
  echo -e "${GREEN}=== Publishing to GitHub ===${NC}"
  echo ""

  # Check if tag exists
  if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag v${VERSION} already exists${NC}"
    echo "Please bump the version in Info.plist first."
    exit 1
  fi

  # Create release
  gh release create "v${VERSION}" \
    "${DMG_PATH}" \
    "${PLUGIN_PATH}" \
    --title "v${VERSION}" \
    --notes "## Download

- **CCStatusBar.dmg** - Mac app (notarized)
- **com.ccstatusbar.streamDeckPlugin** - Stream Deck plugin

## What's New

(Add release notes here)"

  echo ""
  echo -e "${GREEN}Release published: v${VERSION}${NC}"
else
  echo "To publish to GitHub:"
  echo "  ./scripts/release.sh --publish"
  echo ""
  echo "Or manually:"
  echo "  gh release create v${VERSION} ${DMG_PATH} ${PLUGIN_PATH} --title \"v${VERSION}\" --notes \"Release notes\""
fi
