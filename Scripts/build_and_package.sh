#!/bin/bash
# Build MeetingNotes (Beta or Release) and create a validated DMG.
#
# Optional environment:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
#   DEVELOPMENT_TEAM="..."
#   NOTARY_KEYCHAIN_PROFILE="..."
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED_DATA=".deriveddata"
STAGING=""
MOUNT_POINT=""

cleanup() {
    if [[ -n "$MOUNT_POINT" ]] && [[ -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$STAGING" ]] && [[ -d "$STAGING" ]]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    SIGNING_MODE="developer-id"
else
    SIGNING_MODE="ad-hoc"
fi

if [[ "$CONFIGURATION" == "Beta" ]]; then
    APP_NAME="MeetingNotesBeta"
else
    APP_NAME="MeetingNotes"
fi
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

echo "=== Step 1: Build with xcodebuild ==="
SIGN_ARGS=()
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    SIGN_ARGS+=(CODE_SIGN_STYLE=Manual)
    SIGN_ARGS+=(CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION")
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        SIGN_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
else
    SIGN_ARGS+=(CODE_SIGN_STYLE=Manual)
    SIGN_ARGS+=(CODE_SIGN_IDENTITY=-)
fi

xcodebuild -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  "${SIGN_ARGS[@]}" \
  build

echo "=== Step 2: Validate built app metadata ==="
INFO_PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

if [[ "$CONFIGURATION" == "Beta" ]]; then
    EXPECTED_BUNDLE_ID="com.shenminghao.MeetingNotes.beta"
    EXPECTED_DISPLAY_NAME="会议记录 Beta"
    EXPECTED_VERSION="1.2.0"
    EXPECTED_BUILD="12"
else
    EXPECTED_BUNDLE_ID="com.shenminghao.MeetingNotes"
    EXPECTED_DISPLAY_NAME="会议记录"
    EXPECTED_VERSION="1.1.1"
    EXPECTED_BUILD="3"
fi

fail_metadata() {
    echo "ERROR: metadata mismatch: $1" >&2
    exit 1
}
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail_metadata "bundle id"
[[ "$DISPLAY_NAME" == "$EXPECTED_DISPLAY_NAME" ]] || fail_metadata "display name"
[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail_metadata "version"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail_metadata "build"

echo "=== Step 3: Verify codesign, entitlements, hardened runtime ==="
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    EXTRA_SIGN_FLAGS=(--timestamp)
else
    SIGN_IDENTITY="-"
    EXTRA_SIGN_FLAGS=()
fi

# Xcode 26 CopySwiftLibs can leave the compatibility dylib with a stale
# nested signature. Re-sign inside-out (nested dylib first, then the app)
# without --deep, mirroring Xcode's normal signing order.
if [[ -f "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib" ]]; then
    codesign --force ${EXTRA_SIGN_FLAGS[@]+"${EXTRA_SIGN_FLAGS[@]}"} \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
fi
APP_REQUIREMENTS=()
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    APP_REQUIREMENTS=(
        --requirements="$(pwd)/Configuration/MeetingNotesRequirements.req"
    )
fi
codesign --force ${EXTRA_SIGN_FLAGS[@]+"${EXTRA_SIGN_FLAGS[@]}"} \
    --sign "$SIGN_IDENTITY" \
    -o runtime \
    --entitlements Configuration/MeetingNotes.entitlements \
    ${APP_REQUIREMENTS[@]+"${APP_REQUIREMENTS[@]}"} \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

SECURE_TIMESTAMP="SKIPPED_ADHOC"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    SIGN_DETAILS="$(codesign -dvvv "$APP" 2>&1 || true)"
    if ! grep -q "Timestamp=" <<<"$SIGN_DETAILS"; then
        echo "ERROR: Developer ID signature missing secure timestamp" >&2
        exit 1
    fi
    SECURE_TIMESTAMP="PASS"
    if ! grep -q "flags=0x10000" <<<"$SIGN_DETAILS"; then
        echo "ERROR: hardened runtime flag missing" >&2
        exit 1
    fi
fi

ENTITLEMENTS_PLIST="$(codesign -d --entitlements :- "$APP" 2>/dev/null \
    | plutil -p - 2>/dev/null || true)"
grep -q '"com.apple.security.app-sandbox" => true' \
    <<<"$ENTITLEMENTS_PLIST" \
    || { echo "ERROR: sandbox entitlement missing" >&2; exit 1; }
grep -q '"com.apple.security.device.audio-input" => true' \
    <<<"$ENTITLEMENTS_PLIST" \
    || { echo "ERROR: audio-input entitlement missing" >&2; exit 1; }

echo "=== Step 4: Stage validated app and create DMG ==="
STAGING="$(mktemp -d)"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

if [[ "$CONFIGURATION" == "Beta" ]]; then
    DMG="MeetingNotes-$VERSION-beta-build$BUILD.dmg"
    VOLUME_NAME="MeetingNotes Beta"
else
    DMG="MeetingNotes.dmg"
    VOLUME_NAME="MeetingNotes"
fi
rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

NOTARIZATION_STATUS="skipped-ad-hoc"
STAPLER="SKIPPED"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        echo "=== Step 5: Notarize ==="
        NOTARY_LOG="/tmp/meetingnotes-notary-$$.log"
        if xcrun notarytool submit "$DMG" \
            --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
            --wait >"$NOTARY_LOG" 2>&1; then
            NOTARY_STATUS="$(grep -o 'status: [A-Za-z]*' "$NOTARY_LOG" \
                | tail -1 | awk '{print $2}')"
            if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
                echo "ERROR: notarization not accepted: $NOTARY_STATUS" >&2
                exit 1
            fi
            NOTARIZATION_STATUS="accepted"
        else
            echo "ERROR: notarytool submit failed" >&2
            cat "$NOTARY_LOG" >&2
            exit 1
        fi
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        STAPLER="PASS"
    else
        NOTARIZATION_STATUS="skipped-no-profile"
    fi
fi

echo "=== Step 6: Verify mounted DMG app ==="
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_POINT"
DMG_APP="$MOUNT_POINT/$APP_NAME.app"

codesign --verify --deep --strict --verbose=2 "$DMG_APP"

DMG_INFO_PLIST="$DMG_APP/Contents/Info.plist"
DMG_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DMG_INFO_PLIST")"
DMG_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$DMG_INFO_PLIST")"
DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DMG_INFO_PLIST")"
DMG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DMG_INFO_PLIST")"
[[ "$DMG_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail_metadata "mounted bundle id"
[[ "$DMG_DISPLAY_NAME" == "$EXPECTED_DISPLAY_NAME" ]] || fail_metadata "mounted display name"
[[ "$DMG_VERSION" == "$EXPECTED_VERSION" ]] || fail_metadata "mounted version"
[[ "$DMG_BUILD" == "$EXPECTED_BUILD" ]] || fail_metadata "mounted build"

DMG_ENTITLEMENTS_PLIST="$(codesign -d --entitlements :- "$DMG_APP" 2>/dev/null \
    | plutil -p - 2>/dev/null || true)"
grep -q '"com.apple.security.app-sandbox" => true' \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted sandbox entitlement missing" >&2; exit 1; }
grep -q '"com.apple.security.device.audio-input" => true' \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted audio-input entitlement missing" >&2; exit 1; }

GATEKEEPER_ASSESSMENT="NOT_RUN_OR_EXPECTED_UNNOTARIZED"
if [[ "$NOTARIZATION_STATUS" == "accepted" ]]; then
    spctl --assess --type execute -vv "$DMG_APP"
    GATEKEEPER_ASSESSMENT="PASS"
elif [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    GATEKEEPER_ASSESSMENT="SKIPPED_ADHOC"
fi

PACKAGE_VALIDATION="PASS"

echo ""
echo "CONFIGURATION=$CONFIGURATION"
echo "APP=$APP"
echo "DMG=$DMG"
echo "BUNDLE_ID=$BUNDLE_ID"
echo "DISPLAY_NAME=$DISPLAY_NAME"
echo "VERSION=$VERSION"
echo "BUILD=$BUILD"
echo "SIGNING_MODE=$SIGNING_MODE"
echo "NOTARIZATION_STATUS=$NOTARIZATION_STATUS"
echo "PACKAGE_VALIDATION=$PACKAGE_VALIDATION"
