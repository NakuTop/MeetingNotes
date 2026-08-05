# Online Meeting Recovery Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reconstruct legacy online speaker transcripts from saved microphone/system tracks and make unexpected capture termination immediately save, surface, and recover all locally recorded content.

**Architecture:** Extract the existing online per-track transcription/diarization pipeline into a reusable rebuilder used by normal finalization and retry. Add an explicit interruption-finalization path to `MeetingCoordinator`, persist interruption metadata atomically, and expand launch recovery from master-only manifest cleanup to mode-aware repair of all recorded tracks.

**Tech Stack:** Swift 6, Swift Concurrency, SwiftUI Observation, SwiftData, AVFoundation, ScreenCaptureKit, WhisperKit, FluidAudio, XCTest, and XCUITest.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/online-recovery-repair` on branch `codex/online-recovery-repair`.
- Use `@test-driven-development` for every behavior change: write one focused failing test, observe the expected failure, implement only enough to pass, then rerun it.
- Use `@systematic-debugging` for unexpected failures; do not stack speculative fixes.
- Keep physical meeting recordings read-only during development and tests. Tests use temporary fixture directories only.
- Do not stage or delete `.deriveddata-online-recovery-baseline/`; it contains the environment-blocked baseline attempt.
- The initial baseline did not enter any tests because GitHub port 443 failed while SwiftPM fetched `argmax-oss-swift`, `swift-nio`, and `FluidAudio`. Retry verification once network access is available, and distinguish dependency-resolution failures from product failures.
- Do not build a DMG, push GitHub, or replace `/Applications/MeetingNotes.app` in this plan.
- Before claiming completion, use `@verification-before-completion` and `@code-reviewer`.

## Shared test command

Use a fresh derived-data directory and focused test selector:

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/<TestClass>/<testMethod>
```

Expected for a red step: Swift compilation succeeds and the named assertion fails for the missing behavior. Expected for a green step: the named test passes with zero failures.

### Task 1: Extract a reusable online-track transcript rebuilder

**Files:**
- Modify: `MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift`
- Modify: `MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift`

**Step 1: Write a failing delegation test**

Add a rebuilder spy and a test that injects it into `SpeakerAwareTranscriptFinalizer`:

```swift
func testOnlineFinalizationDelegatesTrackReconstruction() async {
    let meetingID = UUID()
    let expected = SpeakerFinalizationOutcome.replacement(
        [attributedDraft(0, 1, "rebuilt", "me", .microphone)],
        sourceRevision: 1
    )
    let rebuilder = OnlineTranscriptRebuilderSpy(outcome: expected)
    let finalizer = SpeakerAwareTranscriptFinalizer(
        reader: RejectingTrackReader(),
        onlineRebuilder: rebuilder
    )

    let result = await finalizer.finalize(
        meetingID: meetingID,
        mode: .online,
        diarizationRequested: true,
        provisional: [],
        transcriptionService: StubTranscriptionService()
    )

    XCTAssertEqual(result, expected)
    XCTAssertEqual(await rebuilder.meetingIDs(), [meetingID])
}
```

**Step 2: Run the focused test and verify red**

Run the shared command with:

```text
MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests/testOnlineFinalizationDelegatesTrackReconstruction
```

Expected: compile failure because `onlineRebuilder` and `OnlineMeetingTranscriptRebuilding` do not exist.

**Step 3: Introduce the reusable component**

In `SpeakerAwareTranscriptFinalizer.swift`, add:

```swift
protocol OnlineMeetingTranscriptRebuilding: Sendable {
    func rebuild(
        meetingID: UUID,
        diarizationRequested: Bool,
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome
}

struct OnlineMeetingTranscriptRebuilder:
    OnlineMeetingTranscriptRebuilding {
    // Move the existing finalizeOnline dependencies and implementation here.
}
```

Move the existing microphone/system read, transcription, merge, coarse attribution, system-only diarization, and assembly logic without changing its error codes. Give `SpeakerAwareTranscriptFinalizer` an injected/default rebuilder and make both online overloads delegate to it. Keep offline logic in the finalizer.

**Step 4: Run finalizer tests and verify green**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests
```

Expected: all `SpeakerAwareTranscriptFinalizerTests` pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift \
  MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift
git commit -m "refactor: share online transcript reconstruction"
```

### Task 2: Rebuild legacy untagged online meetings during speaker retry

**Files:**
- Modify: `MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift`
- Modify: `MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`

**Step 1: Replace the permanent-failure test with a failing reconstruction test**

Change `testOldOnlineMeetingWithoutPerTrackTagsFailsSourceUnavailable` into a test that supplies an online-rebuilder spy and preferred transcription-service provider:

```swift
func testOldOnlineMeetingWithoutTagsRebuildsFromPhysicalTracks() async throws {
    let repository = try makeRetryableMeeting(mode: .online)
    let meeting = try XCTUnwrap(repository.meetings().first)
    try repository.appendTranscript(
        meetingID: meeting.id,
        start: 0,
        end: 1,
        text: "legacy mixed transcript"
    )
    let replacement = [
        draft(0, 1, "我方", "me", .microphone),
        draft(1, 2, "远端", "remote-1", .system),
    ]
    let rebuilder = OnlineTranscriptRebuilderSpy(
        outcome: .replacement(replacement, sourceRevision: 1)
    )
    let useCase = makeUseCase(
        repository: repository,
        onlineRebuilder: rebuilder,
        transcriptionServiceProvider: RetryTranscriptionServiceProvider()
    )

    try await useCase.retry(meetingID: meeting.id)

    let transcripts = try repository.transcripts(meetingID: meeting.id)
    XCTAssertEqual(transcripts.map(\.source), [.microphone, .system])
    XCTAssertEqual(transcripts.map(\.speakerID), ["me", "remote-1"])
    XCTAssertEqual(transcripts.map(\.sourceRevision), [1, 1])
}
```

Add a second failing test proving an online meeting with zero final transcript rows can rebuild from its saved tracks. Add a third test proving a genuine missing-track outcome preserves the old rows and persists `sourceUnavailableCode`.

**Step 2: Run the three focused tests and verify red**

Expected: the legacy/no-transcript cases fail before the rebuilder is called.

**Step 3: Add the selected-model service provider and fallback**

Add a small provider abstraction in `SpeakerDiarizationRetryUseCase.swift`:

```swift
protocol PreferredTranscriptionServiceProviding: Sendable {
    func service() async throws -> any TranscriptionService
}

struct PreferredTranscriptionServiceProvider:
    PreferredTranscriptionServiceProviding {
    let controller: any TranscriptionModelControlling
    let preference: any TranscriptionQualityPreferenceReading

    func service() async throws -> any TranscriptionService {
        let mode = await preference.transcriptionQualityMode()
        return try await controller.service(mode: mode)
    }
}
```

Inject the provider and `OnlineMeetingTranscriptRebuilding` into the retry use case. In `retryOnline`:

- Keep the current tag-only path when all rows have valid microphone/system sources.
- When tags are incomplete or rows are empty, obtain the preferred service and call the shared rebuilder.
- Return a replacement only after the full rebuild result exists.
- Map a genuinely unavailable physical track to `sourceUnavailableCode`.
- Preserve existing rows on cancellation or failure.

Allow `completeSpeakerDiarizationRetry` to accept an optional degradation code so a coarse source-tagged replacement can be saved while remaining retryable. Preserve the default completed behavior for existing callers.

In `AppContainer`, construct the shared live rebuilder from `MeetingTrackAudioReader`, `MeetingAudioSourceLoader`, and `FluidAudioSpeakerDiarizer`, and inject it plus `PreferredTranscriptionServiceProvider` into the retry use case.

**Step 4: Run retry and repository tests**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests
```

Expected: all selected tests pass; existing tagged online retry still loads only the system source and does not re-transcribe.

**Step 5: Commit**

```bash
git add MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift
git commit -m "fix: rebuild legacy online speaker tracks"
```

### Task 3: Make legacy online failures visibly retryable

**Files:**
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`

**Step 1: Write failing view-model tests**

Add tests for an online degraded meeting with `sourceUnavailableCode` and for an online degraded meeting with `transcriptUnavailableCode`:

```swift
XCTAssertEqual(
    viewModel.speakerProcessingWarningMessage,
    "原始分轨录音仍可用于重建，请重新分离说话人。"
)
XCTAssertTrue(viewModel.shouldShowSpeakerDiarizationRetryAction)
XCTAssertTrue(viewModel.canRetrySpeakerDiarization)
```

Retain a separate offline no-transcript case that remains non-retryable.

**Step 2: Run focused tests and verify red**

Expected: online permanent-error cases currently hide the retry action.

**Step 3: Implement mode-aware retry visibility and messaging**

Use `meeting?.mode` when evaluating the two legacy error codes. Allow the action for online meetings because the retry use case can now re-transcribe saved tracks. Keep offline no-transcript failure permanent.

**Step 4: Run `MeetingDetailViewModelTests` and verify green**

**Step 5: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "fix: allow online track reconstruction retry"
```

### Task 4: Finalize and report unexpected capture termination immediately

**Files:**
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`

**Step 1: Write the failing coordinator interruption test**

Create a capture fixture whose stream yields packets and then throws. Without calling `coordinator.stop()`, wait for the interruption reporter and assert:

```swift
XCTAssertEqual(snapshot.state, .ready)
XCTAssertTrue(snapshot.captureFailed)
XCTAssertEqual(masterWriter.finishCount, 1)
XCTAssertEqual(microphoneWriter.finishCount, 1)
XCTAssertEqual(systemWriter.finishCount, 1)
XCTAssertEqual(recordingPresentation.lastPhase, .finished)
XCTAssertEqual(repository.lastFinalization?.lastErrorCode, "capture_interrupted")
XCTAssertEqual(await reporter.meetingIDs(), [meetingID])
```

Also add a race test that starts manual stop as the stream fails and asserts one repository finalization and one writer finish per track.

**Step 2: Run the coordinator tests and verify red**

Expected: the snapshot remains recording, timer remains active, writers are open, and no reporter call exists.

**Step 3: Add atomic interruption persistence**

Add a repository operation that saves, in one context transaction:

```swift
meeting.state = .ready
meeting.endedAt = endedAt
meeting.activeDuration = activeDuration
meeting.lastErrorCode = "capture_interrupted"
meeting.speakerProcessingState = meeting.speakerDiarizationRequested
    ? .degraded : .notRequested
meeting.speakerProcessingErrorCode = meeting.speakerDiarizationRequested
    ? "speaker_diarization_capture_interrupted" : nil
```

Expose it through `MeetingLifecycleRepository` and its live/test adapters.

**Step 4: Add an interruption reporter dependency**

Define:

```swift
protocol MeetingCaptureInterruptionReporting: Sendable {
    func captureInterrupted(meetingID: UUID) async
}
```

Provide a no-op default. Make `MeetingControlRouter` the live main-actor implementation; it reloads/selects the meeting and calls a new `MeetingLibraryViewModel.reportCaptureInterruption` message:

```text
录音意外中断，已保存中断前的内容。请检查会议内容后重新开始录音。
```

**Step 5: Implement interruption finalization without self-await**

Change the stream task to pass the caught failure into the coordinator. Extract lifecycle cleanup shared with normal stop, but make the interruption path skip awaiting the current stream task. It must freeze duration, invalidate health checks, finish the presentation, hide the panel, finish all writers, drain transcription persistence, persist interruption metadata, report once, and release resources.

Guard cleanup with the existing lifecycle operation state so a simultaneous control action cannot finalize twice. Do not auto-restart ScreenCaptureKit.

**Step 6: Run coordinator, repository, and library view-model tests**

Expected: all selected tests pass, including existing manual-stop, deletion-during-finalization, pause/resume, and capture-health cases.

**Step 7: Commit**

```bash
git add MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "fix: finalize interrupted capture immediately"
```

### Task 5: Repair all recording manifests during relaunch recovery

**Files:**
- Modify: `MeetingNotesTests/MeetingRecoveryServiceTests.swift`
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Modify: `MeetingNotes/Recovery/MeetingRecoveryService.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/Views/RootView.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`

**Step 1: Write failing three-track recovery tests**

Create an interrupted online meeting with complete plus incomplete manifest entries on master, microphone, and system tracks. Assert after recovery:

```swift
for track in [AudioTrack.master, .microphone, .system] {
    let manifest = try await fileStore.loadManifest(
        meetingID: meetingID,
        track: track
    )
    XCTAssertTrue(manifest.segments.allSatisfy(\.isComplete))
}
XCTAssertEqual(meeting.state, .ready)
XCTAssertEqual(meeting.activeDuration, expectedMasterDuration, accuracy: 0.001)
XCTAssertEqual(meeting.lastErrorCode, "capture_interrupted_recovered")
XCTAssertEqual(meeting.speakerProcessingState, .degraded)
```

Add cases for master-only offline recovery, absent optional source manifests, and a stranded `.finalizing` online meeting with no transcript rows.

**Step 2: Run `MeetingRecoveryServiceTests` and verify red**

Expected: only the master manifest is cleaned and meeting timing/error metadata remain missing.

**Step 3: Implement mode-aware manifest repair**

For offline meetings, repair `.master`. For online meetings, attempt `.master`, `.microphone`, and `.system` independently. Treat a missing source manifest as a degradation, not a reason to discard other complete tracks. Remove only entries whose `isComplete` is false, save each repaired manifest atomically, and derive active duration from the master complete tail with a safe fallback to the longest available complete track.

Persist recovered meetings as `ready`, set estimated `endedAt`, set `lastErrorCode` to `capture_interrupted_recovered`, and make requested speaker processing degraded/retryable.

**Step 4: Wire startup recovery through the library view model**

Inject a `MeetingRecovering` abstraction into `MeetingLibraryViewModel`. Add `recoverInterruptedMeetings() async` that runs once, reloads meetings, and presents:

```text
已恢复上次意外中断的会议，并保留所有已写入本地的录音。
```

Call it at the start of `RootView`'s existing `.task`, before the normal library load/model preparation. Construct the live service in `AppContainer`.

**Step 5: Run recovery, library, and root-flow tests**

Run focused recovery and view-model suites. If existing UI tests expose startup recovery through launch fixtures, add one fixture with an interrupted meeting and assert the banner and deletability.

**Step 6: Commit**

```bash
git add MeetingNotes/Recovery/MeetingRecoveryService.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotes/Views/RootView.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingRecoveryServiceTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "fix: recover interrupted recording tracks on launch"
```

### Task 6: Regression verification and manual-test build

**Files:**
- Modify if required: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: Run all focused suites**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests \
  -only-testing:MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests \
  -only-testing:MeetingNotesTests/MeetingRecoveryServiceTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: zero failures.

**Step 2: Run the complete arm64 unit suite**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests
```

Expected: all `MeetingNotesTests` pass. If SwiftPM cannot reach GitHub, record the exact resolver error and retry when access returns; do not label it a product failure or a pass.

**Step 3: Run an arm64 Debug build**

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-online-recovery CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

**Step 4: Perform code review**

Use `@code-reviewer` against the approved design. Resolve any correctness, concurrency, data-loss, or privacy finding before proceeding.

**Step 5: Build and open a separate manual-test app when signing is available**

Create only a test copy, preserving `/Applications/MeetingNotes.app`. Verify manually:

1. Open an existing online meeting with the source-marker warning.
2. Click “重新分离说话人” and confirm microphone text becomes “我” and remote speakers are separated.
3. Start an online test recording and use an injected Debug capture failure to confirm the timer stops, the banner appears, and saved audio remains playable/deletable.
4. Relaunch with an interrupted fixture and confirm it becomes ready and retryable.

**Step 6: Update verification evidence and commit**

Append only newly observed results to `docs/testing/manual-apple-silicon-checklist.md`, including any environment block separately from product test results.

```bash
git add docs/testing/manual-apple-silicon-checklist.md
git commit -m "docs: record online recovery verification"
```

If no documentation change is needed, do not create an empty commit.
