#!/bin/bash
# Build MeetingNotes in Release mode and create a DMG
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED_DATA=".deriveddata"
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/MeetingNotes.app"
DMG="MeetingNotes.dmg"
STAGING="/tmp/meetingnotes-dmg-$$"
ASSETS="MeetingNotes/Assets.xcassets"

echo "=== Step 1: Compile asset catalog ==="
mkdir -p "$APP/Contents/Resources"
xcrun actool "$ASSETS" \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /tmp/meetingnotes-partial.plist \
  --product-type com.apple.product-type.application \
  --target-device mac \
  --compress-pngs

echo "=== Step 2: Build with xcodebuild ==="
xcodebuild -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo "=== Step 3: Package DMG ==="
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"
hdiutil create -volname "MeetingNotes" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

echo "=== Done ==="
echo "App: $APP"
echo "DMG: $(pwd)/$DMG"
ls -lh "$DMG"
