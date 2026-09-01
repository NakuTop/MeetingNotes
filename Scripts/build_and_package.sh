#!/bin/bash
# Build MeetingNotes (Beta or Release) and create a validated DMG.
#
# Optional environment:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
#   MEETINGNOTES_LOCAL_SIGNING_IDENTITY="MeetingNotes Local Update Signing"
#   DEVELOPMENT_TEAM="..."
#   NOTARY_KEYCHAIN_PROFILE="..."
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED_DATA=".deriveddata"
STAGING=""
MOUNT_POINT=""
EXPANDED_ENTITLEMENTS=""

cleanup() {
    if [[ -n "$MOUNT_POINT" ]] && [[ -d "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$STAGING" ]] && [[ -d "$STAGING" ]]; then
        rm -rf "$STAGING"
    fi
    if [[ -n "$EXPANDED_ENTITLEMENTS" ]] \
        && [[ -f "$EXPANDED_ENTITLEMENTS" ]]; then
        rm -f "$EXPANDED_ENTITLEMENTS"
    fi
}
trap cleanup EXIT

LOCAL_SIGNING_IDENTITY="${MEETINGNOTES_LOCAL_SIGNING_IDENTITY:-MeetingNotes Local Update Signing}"
LOCAL_CERTIFICATE_SHA1="1487C197139F45D699244AC63B8F46753CBFF9F3"

if [[ "$CONFIGURATION" == "Beta" ]]; then
    LOCAL_REQUIREMENTS_FILE="Configuration/MeetingNotesBetaRequirements.req"
else
    LOCAL_REQUIREMENTS_FILE="Configuration/MeetingNotesStableRequirements.req"
fi

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    SIGNING_MODE="developer-id"
elif security find-identity -v -p codesigning \
    | grep -Fq "$LOCAL_SIGNING_IDENTITY"; then
    SIGNING_MODE="local-identity"
elif [[ "$CONFIGURATION" == "Beta" ]]; then
    echo "ERROR: Beta local signing identity is unavailable" >&2
    exit 1
else
    SIGNING_MODE="ad-hoc"
fi
PUBLISHABLE=NO
APPLE_DISTRIBUTABLE=NO

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
elif [[ "$SIGNING_MODE" == "local-identity" ]]; then
    SIGN_ARGS+=(CODE_SIGN_STYLE=Manual)
    SIGN_ARGS+=(CODE_SIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY")
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
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
APP_EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
MICROPHONE_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy \
    -c 'Print :NSMicrophoneUsageDescription' "$INFO_PLIST")"
EXPECTED_MICROPHONE_USAGE_DESCRIPTION="用于录制并转录会议中的麦克风声音。"

if [[ "$CONFIGURATION" == "Beta" ]]; then
    EXPECTED_BUNDLE_ID="com.shenminghao.MeetingNotes.beta"
    EXPECTED_DISPLAY_NAME="会议记录 Beta"
    EXPECTED_VERSION="1.3.0"
    EXPECTED_BUILD="18"
else
    EXPECTED_BUNDLE_ID="com.shenminghao.MeetingNotes"
    EXPECTED_DISPLAY_NAME="会议记录"
    EXPECTED_VERSION="1.3.0"
    EXPECTED_BUILD="18"
fi

fail_metadata() {
    echo "ERROR: metadata mismatch: $1" >&2
    exit 1
}
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail_metadata "bundle id"
[[ "$DISPLAY_NAME" == "$EXPECTED_DISPLAY_NAME" ]] || fail_metadata "display name"
[[ "$VERSION" == "$EXPECTED_VERSION" ]] || fail_metadata "version"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || fail_metadata "build"
[[ "$MICROPHONE_USAGE_DESCRIPTION" == \
    "$EXPECTED_MICROPHONE_USAGE_DESCRIPTION" ]] \
    || fail_metadata "microphone usage description"

SPARKLE_DEPENDENCY="@rpath/Sparkle.framework/Versions/B/Sparkle"
SPARKLE_RUNPATH="@executable_path/../Frameworks"
[[ -x "$APP_EXECUTABLE" ]] || fail_metadata "app executable"
[[ -f "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
    || fail_metadata "embedded Sparkle framework"
otool -L "$APP_EXECUTABLE" | grep -Fq "$SPARKLE_DEPENDENCY" \
    || fail_metadata "Sparkle load command"
otool -l "$APP_EXECUTABLE" \
    | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { inRPath = 1; next }
        inRPath && $1 == "path" { print $2; inRPath = 0 }
    ' \
    | grep -Fxq "$SPARKLE_RUNPATH" \
    || fail_metadata "embedded framework runpath"

echo "=== Step 3: Verify codesign, entitlements, hardened runtime ==="
EXPANDED_ENTITLEMENTS="$(mktemp \
    /tmp/meetingnotes-expanded-entitlements.XXXXXX)"
cp Configuration/MeetingNotes.entitlements "$EXPANDED_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 $EXPECTED_BUNDLE_ID-spks" \
    "$EXPANDED_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:1 $EXPECTED_BUNDLE_ID-spki" \
    "$EXPANDED_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
    -c 'Delete :com.apple.security.get-task-allow' \
    "$EXPANDED_ENTITLEMENTS" >/dev/null 2>&1 || true
plutil -lint "$EXPANDED_ENTITLEMENTS"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    EXTRA_SIGN_FLAGS=(--timestamp)
    RUNTIME_SIGN_FLAGS=(-o runtime)
    APP_REQUIREMENTS=()
elif [[ "$SIGNING_MODE" == "local-identity" ]]; then
    SIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY"
    EXTRA_SIGN_FLAGS=()
    RUNTIME_SIGN_FLAGS=()
    APP_REQUIREMENTS=(--requirements="$LOCAL_REQUIREMENTS_FILE")
else
    SIGN_IDENTITY="-"
    EXTRA_SIGN_FLAGS=()
    RUNTIME_SIGN_FLAGS=()
    APP_REQUIREMENTS=()
fi

# Xcode 26 CopySwiftLibs can leave the compatibility dylib with a stale
# nested signature. Re-sign inside-out (nested dylib first, then the app)
# without --deep, mirroring Xcode's normal signing order.
if [[ -f "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib" ]]; then
    codesign --force ${EXTRA_SIGN_FLAGS[@]+"${EXTRA_SIGN_FLAGS[@]}"} \
        --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
fi
codesign --force ${EXTRA_SIGN_FLAGS[@]+"${EXTRA_SIGN_FLAGS[@]}"} \
    --sign "$SIGN_IDENTITY" \
    ${RUNTIME_SIGN_FLAGS[@]+"${RUNTIME_SIGN_FLAGS[@]}"} \
    ${APP_REQUIREMENTS[@]+"${APP_REQUIREMENTS[@]}"} \
    --entitlements "$EXPANDED_ENTITLEMENTS" \
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
    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 || true)"
    if ! grep -Fq "identifier \"$EXPECTED_BUNDLE_ID\"" \
        <<<"$DESIGNATED_REQUIREMENT"; then
        echo "ERROR: designated requirement identifier mismatch" >&2
        exit 1
    fi
    if ! grep -q "anchor apple generic" <<<"$DESIGNATED_REQUIREMENT"; then
        echo "ERROR: Developer ID designated requirement anchor missing" >&2
        exit 1
    fi
elif [[ "$SIGNING_MODE" == "local-identity" ]]; then
    SIGN_DETAILS="$(codesign -dvvv "$APP" 2>&1 || true)"
    if grep -Fq "Signature=adhoc" <<<"$SIGN_DETAILS"; then
        echo "ERROR: local identity unexpectedly produced an ad-hoc signature" \
            >&2
        exit 1
    fi
    if grep -Eq 'flags=0x[0-9a-fA-F]+\([^)]*runtime' \
        <<<"$SIGN_DETAILS"; then
        echo "ERROR: local self-signed package unexpectedly enables hardened runtime" \
            >&2
        exit 1
    fi
    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 || true)"
    if grep -Fq "designated => cdhash" <<<"$DESIGNATED_REQUIREMENT"; then
        echo "ERROR: unstable cdhash-only designated requirement" >&2
        exit 1
    fi
    if ! grep -Fq "identifier \"$EXPECTED_BUNDLE_ID\"" \
        <<<"$DESIGNATED_REQUIREMENT"; then
        echo "ERROR: local designated requirement identifier mismatch" >&2
        exit 1
    fi
    if ! grep -Eiq \
        "certificate leaf = H\"${LOCAL_CERTIFICATE_SHA1}\"" \
        <<<"$DESIGNATED_REQUIREMENT"; then
        echo "ERROR: local designated requirement certificate mismatch" >&2
        exit 1
    fi
    codesign --verify --deep --strict --verbose=2 \
        -R="identifier \"$EXPECTED_BUNDLE_ID\" and certificate leaf = H\"$LOCAL_CERTIFICATE_SHA1\"" \
        "$APP"
else
    SIGN_DETAILS="$(codesign -dvvv "$APP" 2>&1 || true)"
    if grep -Eq 'flags=0x[0-9a-fA-F]+\([^)]*runtime' \
        <<<"$SIGN_DETAILS"; then
        echo "ERROR: ad-hoc package unexpectedly enables hardened runtime" \
            >&2
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
grep -q '"com.apple.security.network.client" => true' \
    <<<"$ENTITLEMENTS_PLIST" \
    || { echo "ERROR: network-client entitlement missing" >&2; exit 1; }
grep -Fq "\"$EXPECTED_BUNDLE_ID-spks\"" \
    <<<"$ENTITLEMENTS_PLIST" \
    || { echo "ERROR: Sparkle spks entitlement mismatch" >&2; exit 1; }
grep -Fq "\"$EXPECTED_BUNDLE_ID-spki\"" \
    <<<"$ENTITLEMENTS_PLIST" \
    || { echo "ERROR: Sparkle spki entitlement mismatch" >&2; exit 1; }
if grep -Fq '"com.apple.security.get-task-allow"' \
    <<<"$ENTITLEMENTS_PLIST"; then
    echo "ERROR: get-task-allow entitlement must be absent" >&2
    exit 1
fi

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
hdiutil verify "$DMG"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

if [[ "$SIGNING_MODE" == "local-identity" ]]; then
    NOTARIZATION_STATUS="skipped-local-self-signed"
else
    NOTARIZATION_STATUS="skipped-ad-hoc"
fi
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

if [[ "$SIGNING_MODE" == "developer-id" ]] \
    && [[ "$NOTARIZATION_STATUS" == "accepted" ]] \
    && [[ "$STAPLER" == "PASS" ]]; then
    PUBLISHABLE=YES
    APPLE_DISTRIBUTABLE=YES
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
DMG_MICROPHONE_USAGE_DESCRIPTION="$(/usr/libexec/PlistBuddy \
    -c 'Print :NSMicrophoneUsageDescription' "$DMG_INFO_PLIST")"
[[ "$DMG_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail_metadata "mounted bundle id"
[[ "$DMG_DISPLAY_NAME" == "$EXPECTED_DISPLAY_NAME" ]] || fail_metadata "mounted display name"
[[ "$DMG_VERSION" == "$EXPECTED_VERSION" ]] || fail_metadata "mounted version"
[[ "$DMG_BUILD" == "$EXPECTED_BUILD" ]] || fail_metadata "mounted build"
[[ "$DMG_MICROPHONE_USAGE_DESCRIPTION" == \
    "$EXPECTED_MICROPHONE_USAGE_DESCRIPTION" ]] \
    || fail_metadata "mounted microphone usage description"

DMG_ENTITLEMENTS_PLIST="$(codesign -d --entitlements :- "$DMG_APP" 2>/dev/null \
    | plutil -p - 2>/dev/null || true)"
grep -q '"com.apple.security.app-sandbox" => true' \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted sandbox entitlement missing" >&2; exit 1; }
grep -q '"com.apple.security.device.audio-input" => true' \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted audio-input entitlement missing" >&2; exit 1; }
grep -q '"com.apple.security.network.client" => true' \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted network-client entitlement missing" >&2; exit 1; }
grep -Fq "\"$EXPECTED_BUNDLE_ID-spks\"" \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted Sparkle spks entitlement mismatch" >&2; exit 1; }
grep -Fq "\"$EXPECTED_BUNDLE_ID-spki\"" \
    <<<"$DMG_ENTITLEMENTS_PLIST" \
    || { echo "ERROR: mounted Sparkle spki entitlement mismatch" >&2; exit 1; }
if grep -Fq '"com.apple.security.get-task-allow"' \
    <<<"$DMG_ENTITLEMENTS_PLIST"; then
    echo "ERROR: mounted get-task-allow entitlement must be absent" >&2
    exit 1
fi

GATEKEEPER_ASSESSMENT="NOT_RUN_OR_EXPECTED_UNNOTARIZED"
if [[ "$NOTARIZATION_STATUS" == "accepted" ]]; then
    spctl --assess --type execute -vv "$DMG_APP"
    GATEKEEPER_ASSESSMENT="PASS"
elif [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    GATEKEEPER_ASSESSMENT="SKIPPED_ADHOC"
elif [[ "$SIGNING_MODE" == "local-identity" ]]; then
    GATEKEEPER_ASSESSMENT="SKIPPED_LOCAL_SELF_SIGNED"
fi

PACKAGE_VALIDATION="PASS"
DMG_ABSOLUTE_PATH="$(pwd)/$DMG"
DMG_SIZE="$(stat -f '%z' "$DMG")"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

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
echo "PUBLISHABLE=$PUBLISHABLE"
echo "APPLE_DISTRIBUTABLE=$APPLE_DISTRIBUTABLE"
echo "DMG_ABSOLUTE_PATH=$DMG_ABSOLUTE_PATH"
echo "DMG_SIZE=$DMG_SIZE"
echo "DMG_SHA256=$DMG_SHA256"
