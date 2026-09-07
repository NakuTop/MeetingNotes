# Pure system audio and direct window screenshots Implementation Plan

> **Execution:** Use test-driven-development and isolated implementation/review checkpoints; all tests follow AGENTS.md background-only rules.

**Goal:** Remove desktop-stream overhead from online meetings and make screenshots a one-click window selection.

**Architecture:** Private Core Audio process tap + ephemeral aggregate input + existing AUHAL transport, feeding the existing synchronized microphone/system mixer. Short-lived AppKit selection overlays provide a window filter to the existing one-shot screenshot service.

**Tech Stack:** Swift 6, Core Audio, AUHAL, ScreenCaptureKit screenshot API, AppKit, XCTest.

## Task 1: Direct window selection (isolated implementation)

Files: `MeetingNotes/Recording/MeetingScreenshotCapture.swift`, new `MeetingNotes/Recording/MeetingScreenshotWindowPicker.swift`, `MeetingNotesTests/MeetingScreenshotCaptureTests.swift`, new `MeetingNotesTests/MeetingScreenshotWindowPickerTests.swift`.

1. Add failing pure-policy tests for topmost eligible window, own-app/desktop exclusion, points across multiple displays, empty area, disappearing target, and exactly-once cancel/select. Never display overlays or capture real windows in tests.
2. Run `bash Scripts/test_in_background.sh -only-testing:MeetingNotesTests/MeetingScreenshotWindowPickerTests -only-testing:MeetingNotesTests/MeetingScreenshotCaptureTests` and record RED.
3. Implement the public-metadata hit-test/coordinate policy and injectable selection lifecycle. Wire the production backend to the direct overlay, not SCContentSharingPicker. Overlay event handling remains MainActor; background results cross a terminal gate. No global input hook, Accessibility prompt or live preview stream.
4. Repeat the command for GREEN. Keep current pixel sizing, PNG encoding and screenshot request cancellation tests.
5. Review spec then code quality. Do not commit.

## Task 2: Pure Core Audio session

Files: new `MeetingNotes/Recording/CoreAudioProcessTapSession.swift`, new `MeetingNotesTests/CoreAudioProcessTapSessionTests.swift`.

1. Define low-level HAL API seam for private tap/aggregate creation and destruction; inject the existing `CoreAudioMicrophoneSessionManaging` input reader. Add tests for exclusion/unmuted/private configuration, output shape, start/stop order, partial failure cleanup, caller cancellation, and stale completion after stop/restart.
2. Run background focused tests for RED with a minimal not-implemented seam as necessary; compilation failure alone is not the behavioral reproduction.
3. Implement resource ownership and sample delivery using the existing AUHAL input reader and `PCMConverter` preserve-amplitude policy. No real HAL tap may be created by tests.
4. Run the same tests plus `CoreAudioMicrophoneSampleProviderTests` for GREEN. Inspect all await/cleanup boundaries.

## Task 3: Online pipeline and permissions

Files: new `MeetingNotes/Recording/OnlineAudioCaptureSource.swift`, `MeetingNotes/Recording/ScreenAudioCaptureSource.swift` (shared relay entry only), `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`, `MeetingNotes/Permissions/CapturePermissionClient.swift`, `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`, `MeetingNotes/Views/OnboardingView.swift`, `Configuration/Info.plist`; corresponding focused tests.

1. Add RED tests asserting production online factory returns the tap-backed source and online startup never preflights/requests screen permission.
2. Add synthetic real-mixer tests for independent system/mic samples, startup backlog isolation, per-source tracks, failure, pause/resume/stop, restart/cancellation and prompt terminal stream completion.
3. Wire a dedicated online capture source to the existing frame synchronizer, relay, mixer and transcription-frame builder. Keep system-before-microphone start ordering and no buffered startup PCM leaking into the live clock. Bound delivery and preserve typed system-audio errors.
4. System permission is requested by HAL startup; preserve honest unknown/denied semantics, update explanatory onboarding and typed failure wording, add privacy string. Screenshots keep their separate screen authorization.
5. Run background focused permission/factory/coordinator/audio suites for GREEN; then spec and quality review.

## Task 4: Candidate verification

1. Increment only Beta references 21 to 22 in `project.yml`, `MeetingNotes.xcodeproj/project.pbxproj`, `Scripts/build_and_package.sh`, and the matching update-policy test. Never run xcodegen.
2. Run `git diff --check`; full `bash Scripts/test_in_background.sh` with pinned existing package cache; record exact pass/fail and explicitly excluded interactive tests.
3. Run ordinary `xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Debug -destination 'platform=macOS' build` and record exit.
4. Independent source review, then `nice -n 10 bash Scripts/build_and_package.sh Beta`. Verify DMG hash/size, read-only mounted identity, deep strict signing, Sparkle, sandbox/audio-input/network entitlements and privacy strings. Ensure background-only test flag is absent from the real Beta.
5. Hand off the local Beta with manual gates clearly pending. No git add/commit/push, PR mutation, permission reset, installation or launch.

## Execution record

- Existing worktree and HEAD retained; production identity remains 1.3.0 (18), Beta metadata is now 1.3.1 (22). No project regeneration or microphone/model changes.
- Direct selection RED used a compiling behavioral stub. Initial GREEN: 33/33. Independent review then found hover-A/click-B target drift; eight policy cases and two cancellation cases were added. Supplemental RED: 43 tests, 8 failures; GREEN: 43/43, 0 failures. Production overlay uses the tested identity policy; metadata is re-resolved after overlay dismissal.
- Core Audio lifecycle RED: 8 tests, 17 failures; initial GREEN: 8/8. New online source RED: 4/4 tests failed; the real implementation then passed those four.
- Lifecycle review found three concrete boundaries: pending microphone startup must be cancelled and settled before shared-mic stop, pause failure must terminate its suspended relay, and resume must re-anchor two independently paused clocks. Deterministic RED: 7 tests, 4 failures; combined GREEN: 27/27 (online 7, tap 8, permission 12).
- Integration review required excluding the exact app-owned temporary aggregate UID from microphone candidates, preserving third-party virtual inputs. A fake HAL inventory reproduced the undesired candidate before the narrow filter was added.
- Startup callback failure was independently reproduced as a wrongly propagated cancellation. The run now retains the first real failure, while true caller cancellation still wins for that caller. Existing coordinator permission tests now validate denied/unavailable microphone permission, not obsolete screen preflight.
- The online source reuses existing mixer/conversion primitives but creates no SCStream. The separately invoked smart diagnostic remains unchanged and must not be treated as proof of the new tap backend's real audio delivery.
- Automated checks use the opt-in background-only test host and fake devices/overlays. No actual capture, input automation, app installation, TCC mutation, commit or publication performed.

Final background full unit suite: **1355 passed, 0 failed, exit 0** (`full-background.log`, 2026-09-07). This includes the final aggregate, startup-error, permission and window-intent patches. The two interactive floating-panel tests and all UI automation were deliberately NOT RUN, not counted as passes. Ordinary Debug build: **exit 0** (`debug-build.log`), without the background test-host compilation flag. Pre-existing screenshot completion Sendable and other test/tool warnings remain; this is not a zero-warning claim.

Both independent source reviews closed their findings after re-reading the actual changes.

Beta packaging: **exit 0 / PACKAGE_VALIDATION=PASS**. Artifact: `MeetingNotes-1.3.1-beta-build22.dmg`, **9,746,862 bytes**, SHA256 `52d41ac02169ac3aa1d7db35a338be87506cf07ee0084dc8483ad765368b8170`. Independent `hdiutil verify` passed. Read-only/no-autoopen mount confirmed `会议记录 Beta / com.shenminghao.MeetingNotes.beta / 1.3.1 (22)`, deep strict signature, embedded Sparkle, sandbox/audio-input/network-client entitlements and all microphone/system-audio/screen privacy strings. The real package does not have `LSBackgroundOnly=true`. Signing remains the existing local certificate/designated requirement; **not Developer ID notarized, not published**. Resolved-package SHA remained `07d9b54af514d90b9535bf5c72c8c844c4e72b989bf673a8882d567f956ed221`.

HEAD remains `fa7f420deb5faf65b15998c085e41676d3c8d716`. Existing worktree retained; no commit/push, PR update, installation or app launch. Real packaged capture, authorization, output-device changes, direct click/Escape/multiple monitors and smoothness remain manual acceptance gates.
