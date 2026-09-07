# System Audio Buffer Contract and Diagnostic Alignment Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Correct the real Beta 22 AUHAL render failure and make Settings diagnose the approved pure-system-audio capture path.

**Architecture:** Keep the private Core Audio process tap, owned aggregate, AUHAL/SPSC transport and independent Adaptive microphone. Set the destination buffer's frame length before every render, including overflow scratch storage. Use the same tap session for the diagnostic, including the app's test tone only in this short, explicitly invoked diagnostic; online meetings still exclude app playback. Screen-capture permission is not a proxy for audio-tap authorization.

**Tech Stack:** Swift 6, Core Audio, AVFoundation, XCTest (background-only).

---

## Evidence and scope

- Installed Beta 22 logs: 512 frames at 4 bytes/frame require 2048 bytes; `mDataByteSize=0` yields `kAudio_ParamError`.
- `handleInputCallback` currently sets ring buffer length after render and never sets scratch length before render.
- Apple documents that changing `AVAudioPCMBuffer.frameLength` updates each `AudioBuffer.mDataByteSize`: https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/framelength
- Settings currently uses ScreenCaptureKit and its preflight even though online meetings use process taps.
- No microphone redesign, model changes, timeout-budget changes, upload-schema expansion, screenshot changes, installation, launch, permission resets or publication.

## Task 1 — Reproduce and fix AUHAL buffer contract

Files: `MeetingNotes/Recording/LiveCoreAudioMicrophoneSession.swift`, `MeetingNotesTests/CoreAudioMicrophoneSampleProviderTests.swift`.

1. Add a render fake that rejects zero/incorrect byte lengths exactly as Core Audio does. Exercise first use, multiple channels, changing frame lengths on reused ring slots, and scratch overflow.
2. Run `Scripts/test_in_background.sh -only-testing:MeetingNotesTests/CoreAudioMicrophoneLiveSessionTests` and record the expected assertion failure (no hardware).
3. Set `slot.buffer.frameLength = frames` and `scratch.frameLength = frames` before `api.render`; preserve capacity checks, RT constraints and publication ordering.
4. Rerun the same suite; require zero failures.

## Task 2 — Share pure-audio backend with diagnostics

Files: `MeetingNotes/Recording/CoreAudioProcessTapSession.swift`, `MeetingNotes/AudioDiagnostics/AudioDiagnosticDependencies.swift`, `AudioDiagnosticCoordinator.swift`, `AudioDiagnosticRuleEngine.swift`; existing tap/coordinator/rule tests.

1. Add tests for diagnostic-only inclusion of own output, no screen preflight, backend start/tone/observe/stop ordering, bounded stream cancellation/failure/late-start isolation, and healthy reporting with no screen permission fact.
2. Confirm failures before implementation.
3. Replace the diagnostic SCK runtime with a process-tap runtime, reusing the observation window and session lifecycle. Retain optional legacy screen permission only for existing serialized reports; live diagnostics leave it nil, and use actual capture outcomes. Keep 3-second observation and 12/15-second deadlines and schema v2 allowlist.
4. Preserve typed AUHAL setup/render errors locally; do not serialize raw descriptions, UIDs or paths.
5. Run focused background suites for tap, online capture, AUHAL, diagnostics, Settings and sanitizer.

## Task 3 — Accurate Settings/error wording

Files: `MeetingNotes/AudioDiagnostics/AudioDiagnosticModels.swift`, `MeetingNotes/ViewModels/SettingsViewModel.swift`, `MeetingLibraryViewModel.swift`, `MeetingNotes/Views/AudioDeviceSettingsView.swift`, `Configuration/Info.plist`; associated tests.

1. Test that non-permission render failures do not claim missing permissions; diagnostics identify Core Audio without screen sharing.
2. Implement narrow wording, preserving UI style and consent/preview/upload workflow.

## Task 4 — Review, background validation, Beta 23

1. Independently review the change and error/cancellation ownership. No real capture/desktop automation in tests.
2. Full `Scripts/test_in_background.sh`: unit suite only; two interactive panel cases and UI tests explicitly NOT RUN. Debug build must exit 0.
3. Increment Beta 22 to 23 only in `project.yml`, `MeetingNotes.xcodeproj/project.pbxproj`, `Scripts/build_and_package.sh`; production remains 1.3.0 (18). Do not regenerate the project.
4. Run `./Scripts/build_and_package.sh Beta`; verify DMG, checksum, signature, identity, audio privacy/entitlements. Do not launch or install.
5. Compare existing-work hashes, `git diff --check`, status and HEAD; no commit/push/PR. Hand off Beta 23 for user-controlled real system audio and Settings diagnostic retest; do not call those human checks passed.

## Execution record

- Preflight: branch `codex/beta-1.3.1-performance`, HEAD `fa7f420deb5faf65b15998c085e41676d3c8d716`; existing 51-path working tree preserved.
- Task 1 complete: initial new first-use/stereo/reuse/scratch tests failed with the real `-50` status; setting frame length before both render calls produced 8/8 passing live-session tests. An independent read-only review found no blocker.
- Task 2 complete: production Settings now uses `CoreAudioDiagnosticSessionFactory` and `LiveAudioDiagnosticProcessTapRuntime`; microphone-only preflight leaves legacy screen permission nil, not falsely authorized. Online self-exclusion is unchanged; diagnostic captures its own test tone.
- Additional integration invariant: the real output tester waits for `dataPlayedBack` (one second). A 64-frame-packet queue overflowed with 100 x 512-frame callbacks before observation. This was reproduced as a failing test, then corrected by accumulating metrics immediately on the non-RT delivery queue with constant-memory statistics, not retaining audio arrays. The existing observation clock and 12/15-second deadlines are unchanged.
- Task 3 complete: local errors preserve safe AUHAL phase/status; no generic render failure is labeled permission denial. Settings and privacy descriptions distinguish audio-only diagnostics from screenshot permission. Upload schema v2 and its allowlist are unchanged; raw errors/UIDs/audio are not added.
- Independent diagnostic/lifetime/privacy review: no concrete P0/P1/P2 blockers found. Hardware/UI acceptance explicitly not claimed.
- Development checks: the initial diagnostic compile attempt exposed a mechanical type-rename boundary error, corrected before execution. A subsequent 126-test run found one stale wording assertion; wording was aligned without weakening the assertion. The first 1369-test full run found a stale build-22 packaging assertion; updated to build 23 and reran. These failed logs are retained, not labeled PASS.
- Latest focused diagnostic/tap/library run: 126 passed, 0 failed, exit 0 (`diagnostic-green3.log`).
- Final full background run after version/privacy updates: 1370 passed, 0 failed, exit 0 (`full-background-verified.log`). Two interactive FloatingControl tests and all UI automation: NOT RUN as required.
- Final Debug build: exit 0 (`debug-build-final.log`). Existing screenshot Sendable warning remains outside this fix; no new gate/diagnostic concurrency errors.
- Log directory: `/tmp/MeetingNotes-Audio23.4GjDgU`. All tests used `Scripts/test_in_background.sh`, no real capture or app/UI automation.
- Pre-existing work: 43 of 51 paths remain byte-for-byte unchanged; 8 were deliberately extended for this fix/version/privacy updates. No reset/restore/stash, commit, push or PR changes. Pinned package lock hash unchanged.
- Task 4 complete (local candidate only): `MeetingNotes-1.3.1-beta-build23.dmg`, 9,740,759 bytes, SHA256 `46cd853f8b23e83fb140dc743d59187296ec0dce217a2b103f70e9476c83ecd1`.
- Packager exit 0; `PACKAGE_VALIDATION=PASS`; separate `hdiutil verify` and private read-only mount verification passed. Mounted app: 会议记录 Beta / com.shenminghao.MeetingNotes.beta / 1.3.1 (23); deep strict signature and sandbox/audio-input/network-client/Sparkle entitlements passed. Actual mounted microphone/screen/audio privacy strings match source.
- Signing remains the existing local identity; Apple notarization NOT RUN, no external publication. Production identity remains 1.3.0 (18). No candidate installation/launch, permission reset or real audio capture was performed.
- Final gate: ready for user-controlled Beta 23 online system-audio and Settings smart-diagnostic retest. Human acceptance PENDING; do not treat unit/package evidence as hardware acceptance. HEAD remains `fa7f420deb5faf65b15998c085e41676d3c8d716`, no commit/push/PR changes.
