# Model Cache Recovery and Manual Notion Rearchive Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore downloaded transcription-model availability after every app restart and let users manually archive or force-overwrite either saved meeting document in Notion.

**Architecture:** Derive an uninitialized model controller's availability from the existing on-disk completeness check, while retaining in-process loading and failure states. Keep automatic Notion archive behavior unchanged, broaden the existing saved-document archive action to every stable archive state, and force a managed-section replacement by clearing the prior archived revision when an explicit archive run starts.

**Tech Stack:** Swift 6, SwiftUI Observation, SwiftData, WhisperKit, Notion REST API, XCTest, and XCUITest.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/speaker-aware-transcription` on branch `codex/speaker-aware-transcription`.
- Use `@test-driven-development` for every production change: write one focused failing test, observe the expected failure, add the minimum implementation, then observe green.
- Use `@systematic-debugging` for any unexpected failure instead of stacking speculative changes.
- Do not modify, delete, or stage existing untracked `.deriveddata-*` or `.sandbox-*` directories.
- Do not build a DMG, push GitHub, or replace `/Applications/MeetingNotes.app`.
- Before completion, use `@verification-before-completion` and `@code-reviewer`.

## Shared focused-test command

Use a fresh derived-data directory so existing artifacts remain untouched:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-model-notion-fix \
  -only-testing:MeetingNotesTests/<TestClass>/<testMethod>
```

### Task 1: Restore installed model status from disk

**Files:**
- Modify: `MeetingNotesTests/TranscriptionModelControllerTests.swift`
- Modify: `MeetingNotes/Transcription/TranscriptionModelController.swift`

**Step 1: Write the failing controller test**

Add a test that creates a complete high-accuracy model folder before constructing a new controller:

```swift
func testCachedHighAccuracyReportsReadyBeforePreparation() async throws {
    let storage = makeStorage()
    try makeCompleteModel(at: storage.folder(for: .highAccuracy))
    let spy = TranscriptionModelServiceFactorySpy()
    let controller = makeController(storage: storage, spy: spy)

    let status = await controller.status(for: .highAccuracy)

    XCTAssertEqual(status, .ready)
    XCTAssertTrue(await spy.recordedRequests().isEmpty)
}
```

Also add the inverse case for an incomplete folder to ensure it remains `.notDownloaded`.

**Step 2: Run the two focused tests and verify red**

Expected: the complete-cache test fails with `.notDownloaded`; the incomplete-cache test passes.

**Step 3: Implement disk-derived initial status**

Update `status(for:)` so explicit in-process states win. When no status exists, resolve the descriptor's folder and reuse `storage.hasCompleteModel(at:)`:

```swift
func status(for mode: TranscriptionQualityMode) -> TranscriptionModelStatus {
    if let status = statuses[mode] {
        return status
    }
    let descriptor = TranscriptionModelCatalog.descriptor(for: mode)
    guard let folder = try? storage.resolvedFolder(for: descriptor),
          storage.hasCompleteModel(at: folder) else {
        return .notDownloaded
    }
    statuses[mode] = .ready
    return .ready
}
```

The status check must not create a WhisperKit service or make a network request.

**Step 4: Run `TranscriptionModelControllerTests` and `TranscriptionModelViewModelTests`**

Expected: PASS, including `canPersistSelection(mode: .highAccuracy)` after a fresh status refresh.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionModelController.swift \
  MeetingNotesTests/TranscriptionModelControllerTests.swift
git commit -m "fix: restore downloaded transcription model status"
```

### Task 2: Make an explicit rearchive replace an unchanged managed section

**Files:**
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/NotionArchiveServiceTests.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`

**Step 1: Write the failing repository transition test**

Create and archive a summary, then transition it back to `.archiving`:

```swift
try repository.completeDocumentArchive(meetingID: meetingID, kind: .summary)
XCTAssertEqual(summary.archivedContentRevision, summary.contentRevision)

try repository.updateDocumentArchiveState(
    meetingID: meetingID,
    kind: .summary,
    archiveState: .archiving,
    meetingState: .archiving
)

XCTAssertNil(summary.archivedContentRevision)
```

Repeat the assertion for detailed minutes or use a loop over both kinds.

**Step 2: Run the repository test and verify red**

Expected: FAIL because `updateDocumentArchiveState` currently preserves the last archived revision while moving to `.archiving`.

**Step 3: Implement the minimal transition rule**

In both document branches of `updateDocumentArchiveState`, clear `archivedContentRevision` when entering `.archiving`; continue setting it to the current revision when entering `.archived`. Preserve the existing snapshots so a failed local save rolls back the cleared value.

**Step 4: Run the repository test and verify green**

Expected: PASS for both document kinds.

**Step 5: Write the failing Notion replacement test**

Archive a summary once, capture the managed block IDs and append count, transition it to `.archiving` without changing `contentRevision`, then archive again. Assert that:

```swift
XCTAssertGreaterThan(secondAppendCount, firstAppendCount)
XCTAssertNotEqual(newManagedIDs, oldManagedIDs)
XCTAssertEqual(Set(archivedIDs), Set(oldManagedIDs))
```

This proves explicit rearchive bypasses the unchanged-revision no-op and replaces only the selected managed section.

**Step 6: Run `NotionArchiveServiceTests` and verify green**

Expected: PASS, while the existing idempotent direct-service test still skips an unchanged document unless the caller explicitly transitions it to `.archiving`.

**Step 7: Commit**

```bash
git add MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/NotionArchiveServiceTests.swift
git commit -m "fix: force explicit Notion document replacement"
```

### Task 3: Expose archive, retry, and overwrite for every saved document

**Files:**
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`

**Step 1: Write failing view-model availability tests**

For a generated selected document with Notion enabled, cover `.localOnly`, `.failed`, and `.archived`:

```swift
XCTAssertEqual(viewModel.selectedDocumentArchiveButtonTitle, "归档到 Notion")
XCTAssertTrue(viewModel.canArchiveSelectedDocumentToNotion)
```

Expected titles:

- `.localOnly`: `归档到 Notion`
- `.failed`: `重新归档到 Notion`
- `.archived`: `重新归档并覆盖`
- `.archiving`: `正在归档`, visible but disabled

Also prove the title is `nil` when the selected document does not exist or Notion is disabled.

**Step 2: Run the focused view-model tests and verify red**

Expected: FAIL because the current predicate exposes only `.failed`.

**Step 3: Implement separate visibility and enabled state**

Replace failure-only semantics with:

```swift
var selectedDocumentArchiveButtonTitle: String? { ... }
var canArchiveSelectedDocumentToNotion: Bool { ... }
func archiveSelectedDocumentToNotion() async { ... }
```

The title should exist whenever Notion is enabled and the current type has saved local content. The enabled property must additionally require a stable meeting and no conflicting operation. The action must call `documentManager.retryArchive(meetingID:kind:)`; it must never call a generator.

**Step 4: Add action tests for local-only and archived states**

For both states, call `archiveSelectedDocumentToNotion()` and assert the spy receives only the selected kind in `retriedKinds`, with zero `generatedKinds`.

**Step 5: Run `MeetingDetailViewModelTests` and verify green**

Expected: PASS.

**Step 6: Update the SwiftUI control**

Render the button whenever `selectedDocumentArchiveButtonTitle` is non-nil, use the dynamic title, keep accessibility identifier `meeting.documents.retryArchive`, and disable it with `!canArchiveSelectedDocumentToNotion`. Rename the task-start helper to match the broader action.

**Step 7: Run the view-model suite and build the app target**

Expected: PASS and successful compilation with no stale references to `canRetrySelectedDocumentArchive` or `retrySelectedDocumentArchive`.

**Step 8: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: add manual Notion archive and overwrite action"
```

### Task 4: Regression verification and local test-app replacement

**Files:**
- Verify only; modify tests only if a newly exposed regression requires a test-first fix.

**Step 1: Run all unit tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-model-notion-final \
  -only-testing:MeetingNotesTests
```

Expected: all unit tests pass.

**Step 2: Run all UI tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-model-notion-ui \
  -only-testing:MeetingNotesUITests
```

Expected: all UI tests pass.

**Step 3: Build arm64 Release**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-model-notion-release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: `** BUILD SUCCEEDED **`.

**Step 4: Re-sign and verify the test app artifact**

Sign the Release app with `Configuration/MeetingNotes.entitlements` and verify the final entitlements do not contain `get-task-allow`.

**Step 5: Replace only the local test app**

Quit the currently running `/Users/shenminghao/Applications/MeetingNotes 测试版.app`, copy the verified Release app over that path with `ditto`, and reopen it. Do not touch `/Applications/MeetingNotes.app`.

**Step 6: Final review and status check**

Run `git diff --check`, inspect `git status --short`, review the focused diff against the approved design, and confirm only expected untracked build directories remain.
