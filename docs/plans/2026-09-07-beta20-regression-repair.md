# Beta 20 regression repair Implementation Plan

> **Execution:** Use executing-plans and test-driven-development, one verified fix at a time.

**Goal:** Restore live transcript display, stop screenshot callback crashes, and investigate/fix online system-audio loss without disturbing the user's desktop.

**Architecture:** Preserve capture and transcription architecture. Repair the existing lifecycle and callback boundaries using deterministic background regressions. No publication, real audio upload, model changes, UI redesign or production identity changes.

**Tech Stack:** Swift 6, SwiftData, ScreenCaptureKit, XCTest, AppKit.

## Task 1: Background test safety

- Add a DEBUG-only, explicitly compiled background test entry point in `MeetingNotes/App/MeetingNotesApp.swift`; never initialize the live app/container or display windows in that mode.
- Add `Scripts/test_in_background.sh`: build-for-testing in isolated temporary DerivedData; mark only that generated test host LSBackgroundOnly, sign it locally, then run unit tests only. Skip the two tests that show floating panels. Do not run the UI suite.
- Verify the host is background-only and the unit process remains able to execute XCTest without UI input.

## Task 2: Real picker callback crash

- Evidence: both local Beta 20 crash reports enter the main-actor Objective-C picker observer on replayd's XPC queue and trap in `_checkExpectedExecutor`.
- Add a test invoking the real observer's cancellation entry from a background queue (never present the picker); verify it reproduces before repair.
- Give each selection request its own non-actor observer and thread-safe terminal gate; keep picker presentation/configuration on MainActor. Test selection, cancellation, failure, and late callbacks without opening UI.

## Task 3: Live transcript lifecycle

- Add a regression that opens a detail model while preparing, then appends transcripts while recording and finalizing; assert displayed projection rather than only SwiftData relationships.
- Keep refresh alive through preparing/recording/paused/finalizing and stop when finalization settles. Preserve edits and cached projection semantics.
- Run `bash Scripts/test_in_background.sh -only-testing:MeetingNotesTests/MeetingDetailViewModelTests`.

## Task 4: Online audio

- Trace microphone queue startup, ScreenCaptureKit startup, session timestamp anchoring and mixer emission; use synthetic frames, no real media capture.
- Reproduce any loss with controlled startup/arrival ordering before changing production logic. Retain both source tracks and bounded buffering.
- Run the configuration/relay/mixer/coordinator suites and assert source samples, timing and shutdown behavior.

## Task 5: Verify and deliver

- Run all non-interactive unit tests via the background script, Debug build, diff check and focused source review.
- Increment only Beta to build 21, package locally, verify mounted identities/entitlements/signature/Sparkle and SHA256. Keep stable 1.3.0 (18) untouched.
- Report exact counts, excluded tests and remaining actual-app/hardware gates. No git staging, commit, push or installation.

## Implementation and verification results

### Confirmed faults and narrow repairs

1. **Live projection:** `onMeetingCreated` opens the detail while the record is `.preparing`. The refresh loop used to exit before capture reached `.recording`; the cached display therefore stayed empty despite stored transcripts. Refresh now spans preparing/recording/paused/finalizing. An independently reviewed second boundary was also reproduced: `endedAt` changes SwiftUI's playback task key and cancels the refresh before the final poll. A final `load()` in `defer` now publishes the last persisted snapshot on cancellation.
2. **Screenshot crash:** the two actual Beta 20 crash reports identify both selection and cancellation callbacks on replayd's XPC queue trapping in `_checkExpectedExecutor`. The prior observer was MainActor-isolated. Each request now uses a non-actor observer with an immutable lock-protected terminal gate. MainActor still owns picker presentation/configuration and teardown. Late callbacks own only the old gate. The real Objective-C cancellation callback reproduced the crash in a background unit host before the repair. Real cancellation/update/failure entry points and image completion now pass without presenting the picker or capturing user content. The image-completion path was already safe in the injected background test; it is not claimed as a separate defect.
3. **Online system audio:** the previous microphone-first order buffered microphone PCM during `SCStream.startCapture()`. Its relative timestamps were then anchored at later delivery time, pushing the mixed timeline ahead of live system audio. The deterministic slow-start control lost all 19,200 system samples through the actual synchronizer/mixer. The system-first order, with relay still suspended until both sources are ready, preserves all 19,200 samples. Start failures/cancellation stop owned sources and retain typed cancellation. Neither gain policy nor mixer holdback nor model settings were changed.

### Fresh evidence

- Initial live-projection regression: 1 test failed (2 assertions), as expected against the original loop.
- Original real picker cancellation callback: test host crashed with exit 65, reproducing the actor-executor failure. A restarted runner's zero-test output is **not** a pass.
- Original online startup order: 4 tests failed (5 assertions), including 0 of 19,200 system samples retained. Minimal startup-failure cleanup regression also failed before adding cleanup.
- First repaired focused run: 185 passed / 0 failed, exit 0.
- Finalization/task-replacement regression: 1 failed before the final-load fix. The test waits for the refresh to suspend, calls actual `finalizeMeeting`, cancels the old task and asserts the displayed projection.
- Final background full unit suite: **1,309 passed / 0 failed, exit 0**. Includes the finalization repair and cancellation edge tests.
- Final ordinary Debug build (without the background-host flag): **exit 0**.
- Independent source review: no remaining Critical/Important blocker after finalization repair. Nonblocking follow-up: expand actively-waiting picker-gate cancellation coverage; no runtime defect in its single-waiter contract was found.

### Desktop safety

- Explicit DEBUG background host never creates AppContainer or SwiftUI windows. `LSBackgroundOnly` is changed only in its generated `/tmp` app, not source/installed apps. The safety test verifies prohibited activation and no visible windows.
- **Not run:** all UI automation, `testNoteEditorTemporarilyMakesFloatingPanelKey`, and `testPanelReusesHostingViewAcrossPauseAndRepeatVisibilityCycles`. They are excluded from the 1,309 count, not counted as passed.
- The test script rejects UI-test selectors; skip-only arguments still constrain execution to the unit target. Repository `AGENTS.md` records the user's background-only requirement.
- No app installation, launch, focus/keyboard/mouse automation, permission reset, real audio upload, commit or push. Root checkout's accumulated work is untouched.

### Local package / manual gate

Candidate: `MeetingNotes-1.3.1-beta-build21.dmg`. Stable remains 1.3.0 (18), Beta is 1.3.1 (21), FluidAudio stays 0.13.2.

- Package command: `nice -n 10 bash Scripts/build_and_package.sh Beta`, exit 0; `PACKAGE_VALIDATION=PASS`.
- Independent read-only, no-auto-open mount verification: exit 0; `hdiutil verify` valid; deep/strict codesign verification passed.
- Mounted identity: 会议记录 Beta / `com.shenminghao.MeetingNotes.beta` / 1.3.1 (21).
- Sandbox, audio-input and network-client entitlements are true. Microphone privacy string is `用于录制并转录会议中的麦克风声音。`.
- Embedded Sparkle exists and executable has `@executable_path/../Frameworks` runpath. Real packaged app has no `LSBackgroundOnly` key; background test-host settings did not leak into the candidate.
- Size: 9,671,316 bytes.
- SHA256: `e70d8790512255117af22dda4ae172511a3701c36e768cc487e91a8a8683318b`.
- Existing local signing identity used; not Developer ID notarized. `PUBLISHABLE=NO`, `APPLE_DISTRIBUTABLE=NO`. This is a local retest candidate, not a published release.

Actual packaged-app acceptance remains **PENDING HUMAN** for live transcript appearance, final sentence after stopping, window selection/cancellation/capture, and online microphone plus system audio using the user's normal playback/conferencing app. Synthetic pipeline evidence does not establish device-specific acceptance. No automatic install or publication is authorized by this report.
