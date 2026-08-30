#!/bin/bash
# Fail-closed validation for a publishable MeetingNotes Sparkle release.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: validate_update_release.sh \
  --configuration Beta|Release \
  --artifact <dmg> \
  --appcast <appcast.xml> \
  --expected-version <version> \
  --expected-build <build> \
  --expected-bundle-id <bundle-id> \
  --expected-feed-url <https-url> \
  --expected-public-key <base64-ed25519-public-key> \
  --expected-download-url <https-url>
EOF
}

CONFIGURATION=""
ARTIFACT=""
APPCAST=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_BUNDLE_ID=""
EXPECTED_FEED_URL=""
EXPECTED_PUBLIC_KEY=""
EXPECTED_DOWNLOAD_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --artifact)
            ARTIFACT="${2:-}"
            shift 2
            ;;
        --appcast)
            APPCAST="${2:-}"
            shift 2
            ;;
        --expected-version)
            EXPECTED_VERSION="${2:-}"
            shift 2
            ;;
        --expected-build)
            EXPECTED_BUILD="${2:-}"
            shift 2
            ;;
        --expected-bundle-id)
            EXPECTED_BUNDLE_ID="${2:-}"
            shift 2
            ;;
        --expected-feed-url)
            EXPECTED_FEED_URL="${2:-}"
            shift 2
            ;;
        --expected-public-key)
            EXPECTED_PUBLIC_KEY="${2:-}"
            shift 2
            ;;
        --expected-download-url)
            EXPECTED_DOWNLOAD_URL="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_value() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        echo "ERROR: missing required value: $name" >&2
        exit 2
    fi
}

require_value configuration "$CONFIGURATION"
require_value artifact "$ARTIFACT"
require_value appcast "$APPCAST"
require_value expected-version "$EXPECTED_VERSION"
require_value expected-build "$EXPECTED_BUILD"
require_value expected-bundle-id "$EXPECTED_BUNDLE_ID"
require_value expected-feed-url "$EXPECTED_FEED_URL"
require_value expected-public-key "$EXPECTED_PUBLIC_KEY"
require_value expected-download-url "$EXPECTED_DOWNLOAD_URL"

[[ -f "$ARTIFACT" ]] \
    || { echo "ERROR: artifact not found" >&2; exit 1; }
[[ -f "$APPCAST" ]] \
    || { echo "ERROR: appcast not found" >&2; exit 1; }
[[ "$EXPECTED_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
    || { echo "ERROR: invalid expected version" >&2; exit 1; }
[[ "$EXPECTED_BUILD" =~ ^[0-9]+$ ]] \
    || { echo "ERROR: invalid expected build" >&2; exit 1; }
[[ "$EXPECTED_FEED_URL" == https://* ]] \
    || { echo "ERROR: feed URL must use HTTPS" >&2; exit 1; }
[[ "$EXPECTED_DOWNLOAD_URL" == https://* ]] \
    || { echo "ERROR: download URL must use HTTPS" >&2; exit 1; }

case "$CONFIGURATION" in
    Beta)
        EXPECTED_APP_NAME="MeetingNotesBeta"
        EXPECTED_DISPLAY_NAME="会议记录 Beta"
        EXPECTED_CHANNEL="beta"
        [[ "$EXPECTED_BUNDLE_ID" == \
            "com.shenminghao.MeetingNotes.beta" ]] \
            || { echo "ERROR: Beta bundle ID mismatch" >&2; exit 1; }
        ;;
    Release)
        EXPECTED_APP_NAME="MeetingNotes"
        EXPECTED_DISPLAY_NAME="会议记录"
        EXPECTED_CHANNEL="stable"
        [[ "$EXPECTED_BUNDLE_ID" == \
            "com.shenminghao.MeetingNotes" ]] \
            || { echo "ERROR: Release bundle ID mismatch" >&2; exit 1; }
        ;;
    *)
        echo "ERROR: configuration must be Beta or Release" >&2
        exit 2
        ;;
esac

PUBLIC_KEY_BYTES="$(printf '%s' "$EXPECTED_PUBLIC_KEY" \
    | base64 --decode 2>/dev/null | wc -c | tr -d ' ')"
[[ "$PUBLIC_KEY_BYTES" == "32" ]] \
    || { echo "ERROR: invalid EdDSA public key" >&2; exit 1; }

TEMP_ROOT="$(mktemp -d)"
MOUNT_POINT="$TEMP_ROOT/mount"
MOUNTED=NO
mkdir -p "$MOUNT_POINT"

cleanup() {
    if [[ "$MOUNTED" == "YES" ]]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TEMP_ROOT" ]] && [[ -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

assert_equal() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    [[ "$actual" == "$expected" ]] \
        || fail "$label mismatch"
}

echo "=== Verify DMG integrity, signature, notarization, and stapling ==="
hdiutil verify "$ARTIFACT"
codesign --verify --strict --verbose=2 "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
hdiutil attach "$ARTIFACT" -readonly -nobrowse \
    -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=YES

APP="$MOUNT_POINT/$EXPECTED_APP_NAME.app"
[[ -d "$APP" ]] || fail "expected app is missing from DMG"
INFO_PLIST="$APP/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist missing"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

echo "=== Verify app identity, privacy, channel, and update key ==="
assert_equal "bundle identifier" \
    "$(plist_value CFBundleIdentifier)" "$EXPECTED_BUNDLE_ID"
assert_equal "display name" \
    "$(plist_value CFBundleDisplayName)" "$EXPECTED_DISPLAY_NAME"
assert_equal "short version" \
    "$(plist_value CFBundleShortVersionString)" "$EXPECTED_VERSION"
assert_equal "build version" \
    "$(plist_value CFBundleVersion)" "$EXPECTED_BUILD"
assert_equal "microphone privacy string" \
    "$(plist_value NSMicrophoneUsageDescription)" \
    "用于录制并转录会议中的麦克风声音。"
assert_equal "update channel" \
    "$(plist_value MeetingNotesUpdateChannel)" "$EXPECTED_CHANNEL"
assert_equal "updates enabled" \
    "$(plist_value MeetingNotesUpdatesEnabled)" "YES"
assert_equal "Sparkle feed URL" \
    "$(plist_value SUFeedURL)" "$EXPECTED_FEED_URL"
assert_equal "Sparkle public key" \
    "$(plist_value SUPublicEDKey)" "$EXPECTED_PUBLIC_KEY"
assert_equal "automatic checks" \
    "$(plist_value SUEnableAutomaticChecks)" "true"
assert_equal "automatic installation" \
    "$(plist_value SUAutomaticallyUpdate)" "false"
assert_equal "installer launcher service" \
    "$(plist_value SUEnableInstallerLauncherService)" "true"

echo "=== Verify Developer ID, timestamp, runtime, and nested helpers ==="
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<<"$SIGN_DETAILS" \
    || fail "Developer ID Application: authority missing"
grep -Fq "Timestamp=" <<<"$SIGN_DETAILS" \
    || fail "secure Timestamp= missing"
grep -Eq "flags=0x10000(\(runtime\))?" <<<"$SIGN_DETAILS" \
    || fail "hardened runtime flags=0x10000 missing"
APP_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGN_DETAILS" \
    | tail -1)"
[[ -n "$APP_TEAM_ID" ]] && [[ "$APP_TEAM_ID" != "not set" ]] \
    || fail "Developer ID TeamIdentifier= missing"

EXECUTABLE="$APP/Contents/MacOS/$(plist_value CFBundleExecutable)"
lipo -verify_arch arm64 "$EXECUTABLE" \
    || fail "main executable is not arm64"
otool -L "$EXECUTABLE" \
    | grep -Fq "@rpath/Sparkle.framework/Versions/B/Sparkle" \
    || fail "Sparkle load command missing"
otool -l "$EXECUTABLE" \
    | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { inRPath = 1; next }
        inRPath && $1 == "path" { print $2; inRPath = 0 }
    ' \
    | grep -Fxq "@executable_path/../Frameworks" \
    || fail "embedded framework runpath missing"

SPARKLE_ROOT="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for helper in \
    "$SPARKLE_ROOT" \
    "$SPARKLE_ROOT/Autoupdate" \
    "$SPARKLE_ROOT/Updater.app" \
    "$SPARKLE_ROOT/XPCServices/Downloader.xpc" \
    "$SPARKLE_ROOT/XPCServices/Installer.xpc"; do
    [[ -e "$helper" ]] || fail "nested Sparkle helper missing"
    codesign --verify --strict --verbose=2 "$helper"
    HELPER_SIGN_DETAILS="$(codesign -dvvv "$helper" 2>&1)"
    HELPER_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' \
        <<<"$HELPER_SIGN_DETAILS" | tail -1)"
    assert_equal "nested Sparkle TeamIdentifier" \
        "$HELPER_TEAM_ID" "$APP_TEAM_ID"
done

echo "=== Verify sandbox and Sparkle Mach lookup entitlements ==="
ENTITLEMENTS_FILE="$TEMP_ROOT/entitlements.plist"
codesign -d --entitlements :- "$APP" \
    >"$ENTITLEMENTS_FILE" 2>/dev/null
ENTITLEMENTS_TEXT="$(plutil -p "$ENTITLEMENTS_FILE")"
grep -Fq '"com.apple.security.app-sandbox" => true' \
    <<<"$ENTITLEMENTS_TEXT" \
    || fail "com.apple.security.app-sandbox missing"
grep -Fq '"com.apple.security.device.audio-input" => true' \
    <<<"$ENTITLEMENTS_TEXT" \
    || fail "com.apple.security.device.audio-input missing"
grep -Fq '"com.apple.security.network.client" => true' \
    <<<"$ENTITLEMENTS_TEXT" \
    || fail "com.apple.security.network.client missing"
grep -Fq "$EXPECTED_BUNDLE_ID-spks" <<<"$ENTITLEMENTS_TEXT" \
    || fail "Sparkle -spks Mach lookup entitlement missing"
grep -Fq "$EXPECTED_BUNDLE_ID-spki" <<<"$ENTITLEMENTS_TEXT" \
    || fail "Sparkle -spki Mach lookup entitlement missing"

spctl --assess --type execute -vv "$APP"

echo "=== Verify appcast enclosure and arm64 requirement ==="
xmllint --noout "$APPCAST"
ITEM_XPATH="(//*[local-name()='item'][*[local-name()='enclosure' and @url='$EXPECTED_DOWNLOAD_URL']])[1]"
ENCLOSURE_XPATH="($ITEM_XPATH/*[local-name()='enclosure'])[1]"
ENCLOSURE_URL="$(xmllint --xpath \
    "string(($ENCLOSURE_XPATH)/@url)" "$APPCAST")"
ENCLOSURE_LENGTH="$(xmllint --xpath \
    "string(($ENCLOSURE_XPATH)/@length)" "$APPCAST")"
ENCLOSURE_VERSION="$(xmllint --xpath \
    "string(($ITEM_XPATH/*[local-name()='version'])[1])" \
    "$APPCAST")"
ENCLOSURE_SHORT_VERSION="$(xmllint --xpath \
    "string(($ITEM_XPATH/*[local-name()='shortVersionString'])[1])" \
    "$APPCAST")"
ENCLOSURE_SIGNATURE="$(xmllint --xpath \
    "string(($ENCLOSURE_XPATH)/@*[local-name()='edSignature'])" \
    "$APPCAST")"
HARDWARE_REQUIREMENTS="$(xmllint --xpath \
    "string(($ITEM_XPATH/*[local-name()='hardwareRequirements'])[1])" \
    "$APPCAST")"

assert_equal "appcast enclosure URL" \
    "$ENCLOSURE_URL" "$EXPECTED_DOWNLOAD_URL"
assert_equal "appcast byte length" \
    "$ENCLOSURE_LENGTH" "$(stat -f '%z' "$ARTIFACT")"
assert_equal "sparkle:version" \
    "$ENCLOSURE_VERSION" "$EXPECTED_BUILD"
assert_equal "sparkle:shortVersionString" \
    "$ENCLOSURE_SHORT_VERSION" "$EXPECTED_VERSION"
assert_equal "sparkle:hardwareRequirements" \
    "$HARDWARE_REQUIREMENTS" "arm64"

SIGNATURE_BYTES="$(printf '%s' "$ENCLOSURE_SIGNATURE" \
    | base64 --decode 2>/dev/null | wc -c | tr -d ' ')"
[[ "$SIGNATURE_BYTES" == "64" ]] \
    || fail "sparkle:edSignature is missing or invalid"

swift -e '
    import CryptoKit
    import Darwin
    import Foundation

    guard CommandLine.arguments.count == 4,
          let publicKeyData = Data(
              base64Encoded: CommandLine.arguments[2]
          ),
          let signatureData = Data(
              base64Encoded: CommandLine.arguments[3]
          ) else {
        fputs("Invalid EdDSA verification arguments.\n", stderr)
        exit(2)
    }

    do {
        let artifactData = try Data(
            contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyData
        )
        guard publicKey.isValidSignature(
            signatureData,
            for: artifactData
        ) else {
            fputs("Sparkle EdDSA signature verification failed.\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Sparkle EdDSA signature verification failed.\n", stderr)
        exit(1)
    }
' "$ARTIFACT" "$EXPECTED_PUBLIC_KEY" "$ENCLOSURE_SIGNATURE"

DMG_SHA256="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
DMG_SIZE="$(stat -f '%z' "$ARTIFACT")"

echo "PACKAGE_VALIDATION=PASS"
echo "PUBLISHABLE=YES"
echo "CONFIGURATION=$CONFIGURATION"
echo "VERSION=$EXPECTED_VERSION"
echo "BUILD=$EXPECTED_BUILD"
echo "BUNDLE_ID=$EXPECTED_BUNDLE_ID"
echo "FEED_URL=$EXPECTED_FEED_URL"
echo "DMG_SIZE=$DMG_SIZE"
echo "DMG_SHA256=$DMG_SHA256"
