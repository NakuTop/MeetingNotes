#!/bin/bash
# Unit tests only; never launch the SwiftUI app or interact with the desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

HAS_ONLY_FILTER=NO
for argument in "$@"; do
    case "$argument" in
        -only-testing:MeetingNotesTests/*) HAS_ONLY_FILTER=YES ;;
        -skip-testing:MeetingNotesTests/*) ;;
        *) echo "Only MeetingNotesTests filters are accepted" >&2; exit 2 ;;
    esac
done

TEST_DATA="${MEETINGNOTES_BACKGROUND_DERIVED_DATA:-$(mktemp -d /tmp/MeetingNotes-BackgroundTests.XXXXXX)}"
case "$TEST_DATA" in
    /tmp/MeetingNotes-BackgroundTests.*) ;;
    *) echo "Background test products must be in /tmp/MeetingNotes-BackgroundTests.*" >&2; exit 2 ;;
esac
COMMON=(-project MeetingNotes.xcodeproj -scheme MeetingNotes
    -configuration Debug -destination 'platform=macOS'
    -derivedDataPath "$TEST_DATA"
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
    -parallel-testing-enabled NO)
if [[ -n "${MEETINGNOTES_BACKGROUND_PACKAGE_CACHE:-}" ]]; then
    COMMON+=(-clonedSourcePackagesDirPath "$MEETINGNOTES_BACKGROUND_PACKAGE_CACHE")
fi

xcodebuild "${COMMON[@]}" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG MEETINGNOTES_BACKGROUND_TEST_HOST' \
    build-for-testing

TEST_APP="$TEST_DATA/Build/Products/Debug/MeetingNotes.app"
TEST_INFO="$TEST_APP/Contents/Info.plist"
# Only edit the generated temporary test product, never a installed/local app.
/usr/libexec/PlistBuddy -c 'Delete :LSBackgroundOnly' "$TEST_INFO" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$TEST_INFO"
codesign --force --deep --sign - --preserve-metadata=entitlements "$TEST_APP"
codesign --verify --deep --strict "$TEST_APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$TEST_INFO")" == true ]]

FILTERS=("$@")
if [[ "$HAS_ONLY_FILTER" == NO ]]; then FILTERS+=(-only-testing:MeetingNotesTests); fi
echo 'BACKGROUND_ONLY=YES; UI automation and interactive panel tests are NOT RUN'
xcodebuild "${COMMON[@]}" test-without-building "${FILTERS[@]}" \
    -skip-testing:MeetingNotesTests/FloatingControlTests/testNoteEditorTemporarilyMakesFloatingPanelKey \
    -skip-testing:MeetingNotesTests/FloatingControlTests/testPanelReusesHostingViewAcrossPauseAndRepeatVisibilityCycles
