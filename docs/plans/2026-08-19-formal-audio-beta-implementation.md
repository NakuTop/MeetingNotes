# Formal-Feature Audio Beta Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Beta `1.2.0 (12)` from production `v1.1.1` that changes only audio-device capture, smart diagnostics, and the minimum model download routing needed for fresh-machine compatibility, with high accuracy set to `openai_whisper-large-v3`.

**Architecture:** Start from the clean production commit and replay the reviewed committed audio stack, then port only the final uncommitted adaptive/diagnostic fixes from the preserved Batch worktree. Separate the persistent balanced-model identity from its public remote selector, keep every unrelated production workflow unchanged, and validate the packaged Beta plus a genuinely empty model destination.

**Tech Stack:** Swift 6, Swift Concurrency, SwiftUI, AVFoundation, Core Audio/AUHAL, ScreenCaptureKit, WhisperKit 1.0.0, FluidAudio 0.12.6, XCTest/XCUITest, Xcode build configurations, shell packaging, DMG/codesign tooling.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/formal-audio-beta-1.2.0` on branch `codex/formal-audio-beta-1.2.0`.
- Treat `/Users/shenminghao/Documents/会议记录app` as a read-only source tree. Never reset, restore, clean, stash, or edit its Batch 9–16 changes.
- Use `@test-driven-development` for new behavior and `@systematic-debugging` for any unexpected failure.
- Use `apply_patch` for hand edits. Do not run `xcodegen`; edit `project.pbxproj` only for the reviewed Beta build value.
- Do not port `MeetingNotesModelManifest.swift`, `small_216MB`, model-cache migration hardening, PCM gain, decoding, language, chunking, merger, persistence, or unrelated UI changes.
- Never upload real audio or transcripts. Fresh-model transcription uses a local non-private fixture or generated silence only to prove inference execution.
- Before completion, use `@verification-before-completion` and `@code-reviewer`.

## Verified baseline

- Base commit: `234ff1be37109cdd19f916328d2857954c4f81ba`
- Baseline command:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test -only-testing:MeetingNotesTests
```

- Baseline result on 2026-08-19: `901 passed, 0 failed`, exit `0`.

### Task 1: Replay the reviewed committed audio stack

**Files:**
- Modify/create only the files contained in commits `857d522`, `85079b9`, `554cb89`, `54c7754`, `8ca6170`, `315657f`, `dbbbbbc`, and `8ebe3b4`.
- Audit especially: `MeetingNotes.xcodeproj/project.pbxproj`, `MeetingNotes/Recording/*`, `MeetingNotes/AudioDevices/*`, `MeetingNotes/AudioDiagnostics/AudioDiagnosticDependencies.swift`, `MeetingNotes/ViewModels/SettingsViewModel.swift`, and matching tests.

**Step 1: Verify the source commits are descendants of production**

Run:

```bash
git merge-base --is-ancestor 234ff1be37109cdd19f916328d2857954c4f81ba 8ebe3b41a406db479530f91ce63eef1264321cc0
git log --reverse --oneline 234ff1be37109cdd19f916328d2857954c4f81ba..8ebe3b41a406db479530f91ce63eef1264321cc0
```

Expected: first command exits `0`; the eight listed audio/Beta commits appear in order.

**Step 2: Cherry-pick the reviewed commits in order**

Run:

```bash
git cherry-pick 857d522 85079b9 554cb89 54c7754 8ca6170 315657f dbbbbbc 8ebe3b4
```

Expected: no conflict and no changes to any transcription/model file.

**Step 3: Audit the resulting file boundary**

Run:

```bash
git diff --name-status 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
git diff --check 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
git diff 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD -- MeetingNotes.xcodeproj/project.pbxproj
```

Expected: only reviewed audio/device/diagnostic/Beta configuration and tests; FluidAudio and WhisperKit package references remain present.

**Step 4: Run the committed focused suites**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests \
  -only-testing:MeetingNotesTests/AudioInputDiscoveryTests \
  -only-testing:MeetingNotesTests/CoreAudioMicrophoneSampleProviderTests \
  -only-testing:MeetingNotesTests/LiveMeetingCaptureFactoryTests \
  -only-testing:MeetingNotesTests/ScreenAudioCaptureConfigurationTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests
```

Expected: exit `0`, zero failures.

### Task 2: Port final adaptive startup/cancellation hardening

**Files:**
- Modify: `MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests.swift`
- Modify: `MeetingNotes/Recording/AdaptiveMicrophoneSampleProvider.swift`

**Step 1: Add the deterministic regression tests from the preserved worktree**

Port only these tests and their private deterministic barriers/fakes:

```text
testAdaptiveStartCallerCancellationUnblocks
testCancelledStartupStopsConcreteBackend
testAdaptiveCanRestartAfterCancelledStartup
testLateOldBackendSuccessCannotMutateRestartedSession
testLateOldBackendFailureCannotMutateRestartedSession
testLateOldBackendSuccessDoesNotResetNewTimeline
testLateStaleStartedProviderIsStopped
testLateOldBackendSuccessCannotStopRestartedSameProvider
testConcurrentStopAndCallerCancellationDoesNotDoubleResume
```

Do not import unrelated test helpers.

**Step 2: Run the adaptive suite and verify red**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests
```

Expected: the newly added cancelled-start/restart tests fail against the committed pre-fix implementation.

**Step 3: Port the minimal production fix**

Port only the final caller-cancellation and token-ownership logic from the preserved `AdaptiveMicrophoneSampleProvider.swift`:

- `start()` uses a cancellation handler that resumes the matching pending startup with `CancellationError`, stops the token-owned provider, cancels recovery, and remains idempotent with `stop()`.
- Every shared-state mutation following an asynchronous backend boundary checks `activeToken == token`.
- Immediately after `provider.start(...)` succeeds, a stale attempt stops only its locally owned provider and exits before setting `currentProvider`, capture flags, telemetry, attempts, relay ownership, or timeline state.
- Immediately after `provider.start(...)` throws, a stale attempt exits before recording failure, signaling a continuation, or scheduling recovery.
- `timelineNormalizer.beginBackend()` occurs only after the token is current.

The required success-path shape is:

```swift
let stream = try await provider.start(deviceID: deviceID)
guard activeToken == token else {
    await provider.stop()
    return
}
// Current-token shared mutations may follow here.
```

The catch path must begin with the equivalent current-token guard before any shared mutation.

**Step 4: Run the adaptive and dependent suites**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests \
  -only-testing:MeetingNotesTests/CoreAudioMicrophoneSampleProviderTests \
  -only-testing:MeetingNotesTests/LiveMeetingCaptureFactoryTests
```

Expected: exit `0`, zero failures.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording/AdaptiveMicrophoneSampleProvider.swift \
  MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests.swift
git commit -m "fix(audio): harden adaptive startup cancellation"
```

### Task 3: Port the accepted hard-timeout/report state machine

**Files:**
- Modify: `MeetingNotes/App/LaunchArguments.swift` only if required by the accepted diagnostic preview test fixtures
- Modify: `MeetingNotes/AudioDiagnostics/AudioDiagnosticCoordinator.swift`
- Modify: `MeetingNotes/AudioDiagnostics/AudioDiagnosticDependencies.swift`
- Modify: `MeetingNotes/AudioDiagnostics/AudioDiagnosticModels.swift`
- Modify: `MeetingNotes/AudioDiagnostics/AudioDiagnosticSanitizer.swift`
- Modify: `MeetingNotes/AudioDiagnostics/DeepSeekAudioDiagnosticClient.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Modify: `MeetingNotesTests/AudioDiagnosticCoordinatorTests.swift`
- Modify: `MeetingNotesTests/AudioDiagnosticRuleEngineTests.swift`
- Modify: `MeetingNotesTests/AudioDiagnosticSanitizerTests.swift`
- Modify: `MeetingNotesTests/DeepSeekAudioDiagnosticClientTests.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: Port only the accepted diagnostic regression tests**

Include deterministic coverage for:

- 3-second observation with 12-second microphone and 15-second system deadlines.
- Prompt timeout of a non-cooperative operation.
- Late success/failure ignored after timeout.
- Microphone/system cleanup and no double resume.
- Cancellation before continuation registration.
- Cancellation after registration but before task installation.
- Pre-cancelled caller.
- Cancellation versus timeout and cancellation versus success.
- Microphone/system timeout or failure producing an uploadable safe report and preview.
- Microphone metrics preserved when system diagnostics time out.
- No raw error description in schema-v2 JSON.

Use the existing named tests from the preserved worktree, including:

```text
testCancellationBeforeContinuationRegistrationDoesNotHang
testCancellationAfterContinuationRegistrationBeforeTaskInstallationCancelsLateTasks
testPreCancelledCallerReturnsCancellation
testTimeoutReturnsPromptlyForNonCooperativeOperation
testLateSuccessAfterTimeoutDoesNotReplaceTimeoutReport
testLateFailureAfterTimeoutDoesNotReplaceTimeoutReport
testMicrophoneTimeoutProducesUploadableDiagnosticReport
testSystemAudioTimeoutPreservesSuccessfulMicrophoneEvidence
```

**Step 2: Run the diagnostic tests and verify red**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/AudioDiagnosticCoordinatorTests \
  -only-testing:MeetingNotesTests/AudioDiagnosticRuleEngineTests \
  -only-testing:MeetingNotesTests/AudioDiagnosticSanitizerTests \
  -only-testing:MeetingNotesTests/DeepSeekAudioDiagnosticClientTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests
```

Expected: new timeout/cancellation/report assertions fail before the production port.

**Step 3: Port the minimal diagnostic implementation**

Use the accepted state machine in `AudioDiagnosticOperationTimeoutGate`:

```swift
private enum TerminalResult {
    case success(Value)
    case failure(any Error)
    case timedOut
    case cancelled
}

private var terminalResult: TerminalResult?
private var continuation: CheckedContinuation<Value, Error>?
private var operationTask: Task<Void, Never>?
private var timeoutTask: Task<Void, Never>?
```

All fields remain protected by the existing `NSLock`. Registration atomically stores the continuation or captures an already-buffered terminal result. Completion stores only the first terminal result, clears task references, and resumes outside the lock. Installing a task after terminalization immediately cancels/rejects it. `onCancel` records cancellation synchronously where supported; pre-cancelled callers also throw `CancellationError`.

Preserve these budgets exactly:

```swift
microphoneObservationDuration = 3
microphoneTotalDeadline = 12
systemAudioObservationDuration = 3
systemAudioTotalDeadline = 15
```

Port only the schema-v2 outcome fields, safe issue codes, preview/consent path, and DeepSeek entry required for diagnostic failure upload. Never serialize raw error descriptions, device identifiers, samples, transcripts, tokens, usernames, or paths.

**Step 4: Run all diagnostic/settings tests**

Run the command from Step 2 again.

Expected: exit `0`, zero failures, prompt-race upper bounds satisfied.

**Step 5: Commit**

```bash
git add MeetingNotes/App/LaunchArguments.swift \
  MeetingNotes/AudioDiagnostics MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotesTests/AudioDiagnosticCoordinatorTests.swift \
  MeetingNotesTests/AudioDiagnosticRuleEngineTests.swift \
  MeetingNotesTests/AudioDiagnosticSanitizerTests.swift \
  MeetingNotesTests/DeepSeekAudioDiagnosticClientTests.swift \
  MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "fix(diagnostics): preserve hard timeout cancellation"
```

Before staging, omit `LaunchArguments.swift` if the source audit proves it is only unrelated UI-test scaffolding.

### Task 4: Separate model cache identity from remote selector

**Files:**
- Modify: `MeetingNotesTests/TranscriptionModelCatalogTests.swift`
- Modify: `MeetingNotesTests/TranscriptionModelControllerTests.swift`
- Modify: `MeetingNotes/Transcription/TranscriptionModelCatalog.swift`
- Modify: `MeetingNotes/Transcription/TranscriptionModelController.swift`

**Step 1: Write failing catalog tests**

Add assertions equivalent to:

```swift
func testBalancedKeepsLocalIdentityAndUsesPublicRemoteSelector() {
    let descriptor = TranscriptionModelCatalog.descriptor(for: .balanced)
    XCTAssertEqual(
        descriptor.modelID,
        "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"
    )
    XCTAssertEqual(
        descriptor.downloadSelector,
        "openai_whisper-large-v3-v20240930_turbo"
    )
}

func testHighAccuracyUsesRequestedLargeV3Identity() {
    let descriptor = TranscriptionModelCatalog.descriptor(for: .highAccuracy)
    XCTAssertEqual(descriptor.modelID, "openai_whisper-large-v3")
    XCTAssertEqual(descriptor.downloadSelector, "openai_whisper-large-v3")
}
```

Add a controller test whose service factory records a download request and proves its descriptor carries the public selector while its destination is still resolved from `modelID`.

**Step 2: Run tests and verify red**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/TranscriptionModelCatalogTests \
  -only-testing:MeetingNotesTests/TranscriptionModelControllerTests
```

Expected: compile failure because `downloadSelector` does not exist, plus the old high-accuracy assertion is wrong.

**Step 3: Implement the minimal descriptor change**

Change the descriptor to:

```swift
struct TranscriptionModelDescriptor: Equatable, Sendable {
    let mode: TranscriptionQualityMode
    let modelID: String
    let downloadSelector: String
    let directoryName: String
    let detail: String
}
```

Use these exact entries:

```swift
case .balanced:
    TranscriptionModelDescriptor(
        mode: mode,
        modelID: "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page",
        downloadSelector: "openai_whisper-large-v3-v20240930_turbo",
        directoryName: "balanced",
        detail: "默认，速度和资源占用更均衡"
    )
case .highAccuracy:
    TranscriptionModelDescriptor(
        mode: mode,
        modelID: "openai_whisper-large-v3",
        downloadSelector: "openai_whisper-large-v3",
        directoryName: "high-accuracy",
        detail: "更高多语言精度，下载和处理时间更长"
    )
```

In the controller's default factory, pass:

```swift
WhisperKitTranscriptionService(
    model: request.descriptor.downloadSelector,
    persistentModelFolder: request.folder,
    download: request.download
)
```

Do not modify storage migration or file-install behavior.

**Step 4: Run all model/storage tests**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/TranscriptionModelCatalogTests \
  -only-testing:MeetingNotesTests/TranscriptionModelControllerTests \
  -only-testing:MeetingNotesTests/TranscriptionModelStorageTests \
  -only-testing:MeetingNotesTests/TranscriptionModelFileStoreTests \
  -only-testing:MeetingNotesTests/TranscriptionModelViewModelTests
```

Expected: exit `0`, zero failures; legacy production balanced cache remains addressable.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionModelCatalog.swift \
  MeetingNotes/Transcription/TranscriptionModelController.swift \
  MeetingNotesTests/TranscriptionModelCatalogTests.swift \
  MeetingNotesTests/TranscriptionModelControllerTests.swift
git commit -m "fix(models): route fresh downloads to public selectors"
```

### Task 5: Set Beta build 12 without changing production identity

**Files:**
- Modify: `project.yml`
- Modify manually: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify: `Scripts/build_and_package.sh`

**Step 1: Add/update identity assertions in the packaging validation path**

Ensure the Beta packaging script expects:

```text
display = 会议记录 Beta
bundle = com.shenminghao.MeetingNotes.beta
version = 1.2.0
build = 12
```

and rejects a production identity change.

**Step 2: Update only Beta build references**

Change the Beta `CURRENT_PROJECT_VERSION` from the replayed value to `12` in all three files. Keep production:

```text
会议记录 / com.shenminghao.MeetingNotes / 1.1.1 (3)
```

Do not regenerate the project.

**Step 3: Audit project and resolved build settings**

Run:

```bash
git diff --check
rg -n 'CURRENT_PROJECT_VERSION|MARKETING_VERSION|PRODUCT_BUNDLE_IDENTIFIER|MEETINGNOTES_DISPLAY_NAME' \
  project.yml MeetingNotes.xcodeproj/project.pbxproj Scripts/build_and_package.sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -showBuildSettings
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Beta -showBuildSettings
```

Expected: production Debug is `1.1.1 (3)` with production bundle/display; Beta is `1.2.0 (12)` with Beta bundle/display.

**Step 4: Commit**

```bash
git add project.yml MeetingNotes.xcodeproj/project.pbxproj Scripts/build_and_package.sh
git commit -m "build(beta): prepare formal-feature audio build 12"
```

### Task 6: Perform the final source and privacy audit

**Files:**
- Read all changes from production; modify only if an in-scope defect is proven.

**Step 1: Review every changed file**

Run:

```bash
git diff --stat 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
git diff --name-status 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
git diff 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
git diff --check 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
```

Expected: every file maps to audio/device/diagnostics, narrow model routing, Beta config, tests, or plan docs.

**Step 2: Prove excluded transcription behavior stayed at production**

Compare these files against `234ff1be...` and require no diff except catalog/controller:

```bash
git diff --exit-code 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD -- \
  MeetingNotes/Transcription/TranscriptionModelFileStore.swift \
  MeetingNotes/Transcription/TranscriptionModelStorage.swift \
  MeetingNotes/Transcription/WhisperKitTranscriptionService.swift \
  MeetingNotes/Transcription/MeetingTrackAudioReader.swift \
  MeetingNotes/Transcription/TranscriptMerger.swift
```

Expected: exit `0`.

**Step 3: Audit diagnostic allowlist and static hazards**

Search changed production files for debug output, raw errors, identifiers, paths, samples, transcripts, and credentials. Inspect every hit; pre-existing or safe local-only code is not automatically a failure.

Expected: schema-v2 uploaded JSON contains no device/Core Audio UID, serial number, username, absolute path, samples/audio, transcript, API key, Notion token, or raw `NSError` description.

**Step 4: Structured code review**

Use `@code-reviewer` against the approved design. Stop before packaging for any P0/P1 defect or scope leak.

### Task 7: Run automated validation and clean-model integration

**Files:**
- Do not persist temporary model/audio probe files in the repository.

**Step 1: Debug build**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS' build
```

Expected: exit `0`.

**Step 2: Focused suites**

Run all audio, diagnostics, settings, model catalog/controller/storage/file-store/view-model, live factory, and ScreenCapture configuration suites.

Expected: exit `0`, zero failures; report exact count.

**Step 3: Full unit suite**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test -only-testing:MeetingNotesTests
```

Expected: exit `0`, zero failures, count greater than the `901` production baseline.

**Step 4: Whole scheme**

Check for a conflicting production app process without killing it. If none:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test
```

Expected: record exact unit/UI counts and exit code; do not hide UI launch failures.

**Step 5: Clean balanced-model download and execution probe**

Create a `mktemp -d` directory outside the repository. Use the pinned WhisperKit package and the exact selector `openai_whisper-large-v3-v20240930_turbo` to:

1. resolve uniquely from `argmaxinc/whisperkit-coreml`;
2. download into the empty destination without consulting the app's installed model folder;
3. install through the production `TranscriptionModelFileStore` path into another empty destination;
4. prewarm and load with `download: false` from the installed folder;
5. call transcription locally and confirm the API returns without model/preparation error.

Record the resolved remote folder and key file existence. Remove only the explicitly created temporary directory after recording evidence.

Expected: resolve/download/install/prewarm/load/transcribe all pass. This is the fresh-machine compatibility gate for logical model `openai_whisper-large-v3_turbo_v3_1747_1_10_256Page`.

**Step 6: High-accuracy public identity probe**

Resolve `openai_whisper-large-v3` uniquely in the same pinned repository. Do not reuse or relabel the old `...626MB` cache. A full multi-gigabyte high-accuracy download is optional unless needed to resolve an ambiguity; report exactly whether it was fully prepared or only remotely resolved.

### Task 8: Package and verify Beta 12

**Files:**
- Produce outside git tracking: `MeetingNotes-1.2.0-beta-build12.dmg`

**Step 1: Check signing capability**

Run:

```bash
security find-identity -v -p codesigning
```

Do not expose certificate serials in the user report. If no Developer ID Application identity exists, proceed only with the existing local Beta packaging mode and mark normal Gatekeeper distribution/notarization as unproven.

**Step 2: Build the Beta package**

```bash
./Scripts/build_and_package.sh Beta
```

Expected: `MeetingNotes-1.2.0-beta-build12.dmg` and `PACKAGE_VALIDATION: PASS`.

**Step 3: Verify the DMG and mounted application**

Run `hdiutil verify`, calculate SHA-256 and size, mount read-only, and verify:

```text
CFBundleDisplayName = 会议记录 Beta
CFBundleIdentifier = com.shenminghao.MeetingNotes.beta
CFBundleShortVersionString = 1.2.0
CFBundleVersion = 12
NSMicrophoneUsageDescription = 用于录制并转录会议中的麦克风声音。
com.apple.security.app-sandbox = true
com.apple.security.device.audio-input = true
com.apple.security.network.client = true
codesign verification = PASS
```

Unmount the verified volume. Never stage the DMG.

**Step 4: Actual packaged-app handoff**

Launch the mounted/copied packaged Beta, but record microphone, diagnostic, offline meeting, balanced model, and affected-hardware outcomes as `PENDING HUMAN` until the user performs them. If a real UI cancellation path exists, include it in diagnostic smoke; do not invent a cancel button.

**Step 5: Final git safety check**

```bash
git status --short
git diff --check
git log --oneline --decorate 234ff1be37109cdd19f916328d2857954c4f81ba..HEAD
```

Expected: source tree clean, DMG untracked/ignored, production branch and original dirty Batch worktree unchanged. Do not push, merge, update a PR, or replace production unless separately authorized.
