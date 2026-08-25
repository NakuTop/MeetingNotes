# Model-Ready Meeting Start Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent model preparation from creating an uncloseable meeting by keeping the coordinator idle until the selected transcription model is ready.

**Architecture:** Prepare the transcription queue after permissions but before the coordinator enters `.preparing` or creates a repository record. Preserve the existing shared model-download controller and all post-creation capture, deletion, presentation, and cleanup behavior.

**Tech Stack:** Swift 6, Swift Concurrency actors, SwiftUI observation, SwiftData repository adapters, XCTest, Xcode 17.

---

## Initial source-repair execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/formal-audio-beta-1.2.0`.
- Use `@test-driven-development`: add deterministic RED coverage before editing production code.
- During the source-repair and review gate, do not change model selectors,
  decoding, audio capture, diagnostics, timeouts, transcript behavior, versions,
  project files, or packaging scripts.
- Do not commit, push, or update a PR during this repair/validation pass.
- Use `apply_patch` for hand edits and never run `xcodegen`.

### Task 1: Reproduce pending-model startup without a meeting

**Files:**
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Add a deterministic blocking transcription factory**

Add a test-only `BlockingCoordinatorTranscriptionFactory` actor that records
entry into `makeQueue()`, waits on a checked-continuation barrier, and then
either returns the existing fake transcriber or throws a configured error.
Observe entry through a bounded XCTest expectation so an unexpected missing
factory call fails instead of suspending the suite forever.

**Step 2: Add the pending-model regression**

Add `testPendingTranscriptionModelDoesNotCreateOrLockMeeting`. Start the
coordinator, wait for the factory barrier, and assert before release:

```swift
let snapshot = await fixture.coordinator.snapshot()
XCTAssertEqual(snapshot.state, .idle)
XCTAssertNil(snapshot.meetingID)
XCTAssertTrue(await fixture.repository.createdMeetingIDs().isEmpty)
XCTAssertTrue(await fixture.panel.calls().isEmpty)
XCTAssertFalse(snapshot.state.blocksCaptureSettingsChanges)
```

Also assert no writer or capture factory work has started. Release the barrier,
await `start`, and verify the normal recording state and `panel.show`.

**Step 3: Add the preparation-failure regression**

Add `testTranscriptionModelFailureBeforeMeetingCreationLeavesNoMeeting`.
Configure the factory to throw and assert the caller receives the error,
the snapshot remains idle with no meeting ID, the repository has no created
meeting, and no writer/capture/panel work occurs.

**Step 4: Preserve permission-first ordering**

Add `testDeniedPermissionDoesNotPrepareTranscriptionModelOrCreateMeeting`. Configure
the required permission as denied, await the start error, and assert the
transcription factory entry count is zero along with no meeting, writer,
capture, or panel work.

**Step 5: Run the new tests and verify RED**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests/testPendingTranscriptionModelDoesNotCreateOrLockMeeting \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests/testTranscriptionModelFailureBeforeMeetingCreationLeavesNoMeeting \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests/testDeniedPermissionDoesNotPrepareTranscriptionModelOrCreateMeeting
```

Expected: the first two tests fail because the current code has already entered
`.preparing` and created a repository record; the permission-order test passes.

### Task 2: Move model readiness ahead of meeting creation

**Files:**
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Implement the minimal sequencing change**

In `MeetingCoordinator.start(mode:onMeetingCreated:)`:

1. Validate `.prepare` on a copied state machine before the first suspension,
   without assigning it to the coordinator.
2. Keep lifecycle serialization and permission validation.
3. Call `dependencies.transcriptionFactory.makeQueue()` before installing
   `.preparing` and before `repository.createMeeting`.
4. Retain the returned queue as the local `newTranscriber` startup resource.
5. Check caller cancellation after queue creation, time/metadata reads, and
   immediately before persistence.
6. After `createMeeting` returns, retain `newMeetingID` before checking
   cancellation so rollback can delete an unpublished record.
7. Remove the later duplicate queue creation while preserving actor ownership,
   discard checks, cleanup, and the remaining startup order.

Do not alter `TranscriptionModelController` or cancellation of its shared
preparation task.

**Step 2: Run the three new tests and verify GREEN**

Run the Task 1 command again.

Expected: 3 passed, 0 failed, exit 0.

**Step 3: Cover state and cancellation interleavings**

Add deterministic tests proving:

- A second start while already recording throws without changing the original
  meeting, panel, capture ownership, or ability to stop.
- Cancellation after model readiness but before repository entry returns
  `CancellationError` with no created meeting or runtime resource.
- Cancellation while repository creation is suspended rolls back the returned
  identifier and leaves no saved meeting or runtime resource.

Run these three tests together with the original three; expected result is
6 passed, 0 failed, exit 0.

**Step 4: Run meeting lifecycle regressions**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests \
  -only-testing:MeetingNotesTests/TranscriptionModelControllerTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests
```

Expected: exit 0 and zero failures, including the existing deletion-during-start
and shared-model-preparation tests.

### Task 3: Audit and validate the narrow repair

**Files:**
- Review: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Review: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Audit the exact diff**

Run:

```bash
git diff --check
git diff --stat
git diff -- MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
```

Expected: only the approved sequencing change, deterministic test seam/tests,
and the two plan documents; no version or unrelated source changes.

**Step 2: Run the Debug build**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS' build
```

Expected: exit 0.

**Step 3: Run all unit tests**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test -only-testing:MeetingNotesTests
```

Expected: exit 0 and zero failures.

**Step 4: Stop before packaging**

Report the source diff, RED/GREEN evidence, build/unit results, and current git
status. Do not increment Beta or build a DMG until the user reviews this repair.

### Task 4: Package the reviewed repair as Beta 13

After the source-review gate was completed and packaging was authorized, update
only the Beta build number from 12 to 13 in:

- `project.yml`
- `MeetingNotes.xcodeproj/project.pbxproj`
- `Scripts/build_and_package.sh`

Keep the production identity at `1.1.1 (3)`, do not regenerate the Xcode
project, and build and verify `MeetingNotes-1.2.0-beta-build13.dmg`. This later
packaging step does not alter the source-repair scope described above.
