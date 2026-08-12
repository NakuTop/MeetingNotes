#!/bin/bash
# Build MeetingNotes in Release mode and create a DMG
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED_DATA=".deriveddata"
if [ "$CONFIGURATION" = "Beta" ]; then
  APP_NAME="MeetingNotesBeta"
  DMG="MeetingNotes-1.2.0-beta-build4.dmg"
  VOLUME_NAME="MeetingNotes Beta"
else
  APP_NAME="MeetingNotes"
  DMG="MeetingNotes.dmg"
  VOLUME_NAME="MeetingNotes"
fi
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
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
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  build

echo "=== Step 3: Package DMG ==="
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"
hdiutil create -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

echo "=== Step 4: Verify signature and entitlements ==="
codesign --force --deep --sign - \
  --entitlements Configuration/MeetingNotes.entitlements \
  "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | sed -n '1,40p'

echo "=== Done ==="
echo "App: $APP"
echo "DMG: $(pwd)/$DMG"
ls -lh "$DMG"
