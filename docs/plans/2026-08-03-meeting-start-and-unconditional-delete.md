# Meeting Start and Unconditional Delete Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show a newly created meeting immediately and make every meeting safely deletable together with all local files, including meetings that are preparing, recording, paused, or abandoned after an interrupted launch.

**Architecture:** Add a record-created callback to the start boundary so the library can select the persistent row before audio setup completes. Replace passive deletion permission checks with an async coordinator discard path, make transcription queues cancellable, and serialize deletion behind cancellable per-meeting UI work before deleting files and then the repository row.

**Tech Stack:** Swift 6, SwiftUI Observation, actors and structured concurrency, SwiftData, XCTest, XCUITest, Xcode 17.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/speaker-aware-transcription` on `codex/speaker-aware-transcription`.
- Follow `@test-driven-development`: add one focused regression, observe the intended failure, implement the minimum change, and observe green.
- Use `@systematic-debugging` for unexpected failures rather than speculative edits.
- Preserve the destructive confirmation. Do not delete any of the user's existing meetings during automated testing or diagnostics.
- Do not touch or stage the existing untracked `.deriveddata-*` and `.sandbox-*` directories.
- Do not build a DMG, push GitHub, or replace `/Applications/MeetingNotes.app`.
- Before completion, use `@verification-before-completion` and `@requesting-code-review`.

## Shared focused-test command

Use a fresh DerivedData directory and the existing package cache:

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-start-delete-fix \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  -only-testing:MeetingNotesTests/<TestClass>/<testMethod> \
  CODE_SIGNING_ALLOWED=NO
```

### Task 1: Select the meeting as soon as its record exists

**Files:**
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotes/App/LaunchArguments.swift`

**Step 1: Write the failing progressive-selection test**

Add a `MeetingStarting` spy that creates/inserts a `preparing` record, calls `onMeetingCreated`, and then blocks before returning. Start the view-model operation in a task, wait for the callback, and assert while the starter is still blocked:

```swift
XCTAssertEqual(viewModel.selectedMeetingID, createdMeeting.id)
XCTAssertEqual(viewModel.selectedMeeting?.state, .preparing)
XCTAssertTrue(viewModel.isStarting)
```

Also keep the existing assertion that the created meeting wins over an older pinned meeting.

**Step 2: Run the focused test and verify RED**

Expected: the test does not compile because `MeetingStarting.start` has no creation callback, or it observes `selectedMeetingID == nil` until the starter returns.

**Step 3: Extend the start boundary**

Change the protocol requirement to:

```swift
func start(
    mode: MeetingMode,
    onMeetingCreated: @Sendable @escaping (UUID) async -> Void
) async throws -> UUID
```

Keep a default convenience overload that passes a no-op callback so direct coordinator callers remain source-compatible. Update production, UI-test, and test starters.

**Step 4: Notify after persistence and select on the main actor**

In `MeetingCoordinator.start`, invoke the callback immediately after `createMeeting` succeeds. In `MeetingLibraryViewModel.startMeeting`, reload and select the callback identifier before awaiting the rest of startup. Track the active start task and created identifier so a later delete can cancel the matching startup.

Treat `CancellationError` from an intentionally discarded start as a silent reload, not a permission/capture alert.

**Step 5: Run all `MeetingLibraryViewModelTests` and verify GREEN**

Expected: progressive selection and existing start/retry/error tests pass.

**Step 6: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotes/App/LaunchArguments.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "fix: show meeting while recording starts"
```

### Task 2: Make live transcription discardable

**Files:**
- Modify: `MeetingNotesTests/TranscriptionQueueTests.swift`
- Modify: `MeetingNotes/Transcription/TranscriptionQueue.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/App/LaunchArguments.swift`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write a failing queue-cancellation test**

Use a controllable transcription service that blocks after work begins. Enqueue one active and one waiting chunk, call `cancel()`, then release the service. Assert that the queue publishes no further draft, has an idle/empty snapshot, and ignores future enqueue requests.

**Step 2: Run the queue test and verify RED**

Expected: the test does not compile because `TranscriptionQueue` has no cancellation API.

**Step 3: Implement terminal queue cancellation**

Add an `isCancelled` flag and `cancel()` operation that cancels the worker task, clears waiting/failed/deferred content, finishes the update stream, and prevents later enqueue/retry work. In the worker, check cancellation after every service await and before appending/yielding results so a non-cooperative service cannot publish after discard.

**Step 4: Extend the coordinator queue protocol**

Add `cancel()` to `MeetingTranscriptionQueueing`, forward it from `LiveMeetingTranscriptionQueue`, and implement it in the UI-test and coordinator-test queues. The coordinator test fake must record cancellation separately from `drain` and `finishUpdates`.

**Step 5: Run `TranscriptionQueueTests` and verify GREEN**

Expected: cancellation regression and all buffering/retry/merge tests pass.

**Step 6: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionQueue.swift \
  MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift \
  MeetingNotes/App/LaunchArguments.swift \
  MeetingNotesTests/TranscriptionQueueTests.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: cancel discarded transcription queues"
```

### Task 3: Discard coordinator-owned meetings without finalization

**Files:**
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`

**Step 1: Replace deletion-guard tests with active-discard tests**

Add coordinator cases for `preparing`, `recording`, and `paused`. After `prepareForDeletion(id:)`, assert:

```swift
XCTAssertNil(snapshot.meetingID)
XCTAssertEqual(snapshot.state, .idle)
XCTAssertEqual(await transcriber.cancelCount(), 1)
XCTAssertFalse(events.contains("repository.finalize"))
XCTAssertFalse(events.contains("speaker.finalize"))
XCTAssertFalse(events.contains("repository.delete"))
```

The repository row is deliberately left for the library deletion pipeline.

**Step 2: Add a startup/deletion race test and verify RED**

Block a start dependency after the record-created callback, request deletion preparation, then release the dependency. Assert that startup ends with `CancellationError`, its temporary capture/writers are closed, the panel never remains visible, and coordinator state cannot return to recording.

Expected: RED because only `canDeleteMeeting` exists and active startup cannot be discarded.

**Step 3: Introduce `MeetingDeletionPreparing`**

Replace `MeetingDeletionGuarding` with:

```swift
protocol MeetingDeletionPreparing: Sendable {
    func prepareForDeletion(id: UUID) async throws
}
```

Provide a no-op default for view-model tests and make `MeetingCoordinator` the production implementation.

**Step 4: Implement idempotent discard coordination**

Track discard-requested meeting identifiers and lifecycle waiters. Set coordinator ownership immediately after the meeting row is created. Check task cancellation/discard after each awaited startup/finalization boundary. When deletion targets a busy lifecycle, request cancellation, stop any published capture/queue, and wait until its cleanup completes.

For an active recording or pause, stop capture, wait for stream shutdown, cancel transcription updates, close all writers, hide the panel, finish the live presentation without finalizing persistence, release resources, and reset the coordinator to idle. Do not call the speaker finalizer or repository meeting deletion.

**Step 5: Preserve ordinary failure semantics**

Normal startup failures may continue removing their newly created row. Intentional discard must leave the row for file-first library deletion and surface `CancellationError` to the start caller. Normal `stop()` behavior and failed-finalization recovery must remain unchanged.

**Step 6: Run `MeetingCoordinatorTests` and verify GREEN**

Expected: new discard/race tests and all capture, stop, diarization, health, and finalization regressions pass.

**Step 7: Commit**

```bash
git add MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: discard active meetings before deletion"
```

### Task 4: Allow deletion in every state and wait for cancellable UI work

**Files:**
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Create: `MeetingNotesTests/MeetingOperationGateTests.swift`
- Modify: `MeetingNotes/Domain/MeetingOperationGate.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/MeetingSidebarView.swift`

**Step 1: Update availability and ordering tests**

Change the state matrix to require `canDelete == true` for every `RecordingState`. Replace busy-recording rejection with a test that verifies this order:

```text
selection cleared -> deletion preparer -> playback stopped -> directory deleted -> repository row deleted -> library reloaded
```

Keep the existing regression proving repository deletion is skipped if directory deletion throws.

**Step 2: Add an operation-gate waiter test**

Acquire a summary operation, start an async deletion acquire, confirm it remains suspended, release summary, then verify deletion owns the gate and can release it. Add cancellation cleanup if the waiting task is cancelled.

**Step 3: Run the new tests and verify RED**

Expected: recording-state availability fails, deletion still rejects coordinator ownership, and the gate has no waiting acquire.

**Step 4: Add ordered asynchronous acquisition**

Extend `MeetingOperationGate` with a cancellation-safe async acquire that queues waiters per meeting and transfers ownership on release. Preserve the existing immediate acquire behavior for rename, summary/archive, and speaker retry.

**Step 5: Implement unconditional library deletion**

Return `true` from `canDelete` for all states. At delete start, clear matching selection to trigger view disappearance, cancel the matching active start task, await the delete gate, call `prepareForDeletion`, stop playback, delete the meeting directory, then delete the repository row and reload.

If coordinator preparation or file deletion fails, retain the row and present a retryable error. Keep duplicate-delete suppression.

**Step 6: Cancel every detail-scoped operation**

Store the speaker-diarization retry task alongside rename and document tasks in `MeetingDetailView`, cancel and invalidate all three in `onDisappear`, and prevent stale completions from updating the removed meeting.

**Step 7: Update the confirmation copy**

State that an in-progress recording will be stopped and all local recording, transcript, and summary content permanently deleted, while any existing Notion page remains unchanged.

**Step 8: Run the related suites and verify GREEN**

Run `MeetingOperationGateTests`, `MeetingLibraryViewModelTests`, `MeetingDetailViewModelTests`, and `MeetingCoordinatorTests`.

**Step 9: Commit**

```bash
git add MeetingNotes/Domain/MeetingOperationGate.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/Views/MeetingSidebarView.swift \
  MeetingNotesTests/MeetingOperationGateTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "fix: delete meetings in every lifecycle state"
```

### Task 5: Verify the full app and refresh only the test installation

**Files:**
- Verify: all modified source and tests
- Build artifact: `.deriveddata-start-delete-release/Build/Products/Release/MeetingNotes.app`

**Step 1: Run the complete unit test target**

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-start-delete-final \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  -only-testing:MeetingNotesTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all unit tests pass with zero failures.

**Step 2: Run the focused library UI regression**

Run or add a deterministic UI launch-argument case that starts a meeting, observes the detail screen before startup completes, confirms deletion, and verifies the history row disappears. Use only the UI-testing in-memory/container fixtures, never the user's real library.

Expected: PASS with no stuck home screen and no residual meeting row.

**Step 3: Request code review and apply only verified findings**

Use `@requesting-code-review`, inspect the complete diff against this design, and rerun any suite affected by fixes.

**Step 4: Build and sign arm64 Release**

```bash
xcodebuild build \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-start-delete-release \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Re-sign with `Configuration/MeetingNotes.entitlements`, then verify deep signature, arm64 architecture, bundle identifier, and absence of `get-task-allow`.

**Step 5: Replace only the local test copy**

Replace `/Users/shenminghao/Applications/MeetingNotes 测试版.app` with the verified build using a staged copy and reversible backup, then open it for manual testing. Leave `/Applications/MeetingNotes.app` unchanged.

**Step 6: Final repository checks**

Run `git diff --check`, confirm no tracked changes remain, and verify that only the intended commits were added. Do not create a DMG or push GitHub.
