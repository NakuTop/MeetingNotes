# Editable Meetings, Notion Replacement, and GitHub Updates Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add durable in-meeting text correction, automatic local document saving, explicit whole-page Notion replacement, and secure stable/Beta GitHub updates without changing accepted audio or transcription-model behavior.

**Architecture:** Persist transcript corrections independently from generated transcript rows and derive one canonical meeting document for UI, summary generation, replacement, and Notion. Extend the existing Notion checkpoint machinery to snapshot and replace the complete child-page body. Wrap Sparkle 2 behind a testable update driver and a fail-closed activity policy.

**Tech Stack:** Swift 6, SwiftUI, Observation, SwiftData, XCTest/XCUITest, Notion REST API, Sparkle 2.9.2 through Swift Package Manager, GitHub Actions/Releases, Apple Developer ID and notarization.

---

## Execution constraints

- Work only in `.worktrees/codex/formal-audio-beta-1.2.0` on
  `codex/formal-audio-beta-1.2.0`.
- Start from a clean worktree and preserve the accepted microphone,
  diagnostics, model identities, decoding, PCM, chunking, merger, and
  diarization behavior.
- Do not run `xcodegen`. Edit `project.yml` and
  `MeetingNotes.xcodeproj/project.pbxproj` deliberately and verify that
  WhisperKit and FluidAudio remain present.
- Never add a Sparkle private key, Apple certificate, Notion token, API key, or
  notarization credential to the repository or command output.
- Do not publish a GitHub Release or appcast until the user authorizes the
  release gate and Developer ID/notarization prerequisites exist.
- Follow TDD: add one failing behavior test, observe the expected failure, make
  the smallest production change, rerun the focused suite, then commit.

## Reference material

- Sparkle 2.9.2 release: <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.2>
- SwiftUI/programmatic setup: <https://sparkle-project.org/documentation/programmatic-setup/>
- Sandboxed-app integration: <https://sparkle-project.org/documentation/sandboxing/>
- Publishing and EdDSA: <https://sparkle-project.org/documentation/publishing/>

### Task 1: Persist durable transcript corrections

**Files:**

- Create: `MeetingNotes/Persistence/Models/TranscriptCorrectionRecord.swift`
- Create: `MeetingNotes/Editing/TranscriptCorrectionResolver.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Create: `MeetingNotesTests/TranscriptCorrectionResolverTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write the failing model and resolver tests**

Cover these contracts:

```swift
func testMeetingWithoutCorrectionsUsesGeneratedTranscriptText()
func testCorrectionWinsOverGeneratedTextForExactTranscriptIDs()
func testCorrectionReattachesBySourceAndTimeAfterIDsChange()
func testAmbiguousOverlapDoesNotApplyOneCorrectionTwice()
func testUnmatchedCorrectionRemainsVisibleAtItsAnchor()
func testDeletingMeetingCascadesTranscriptCorrections()
```

Use deterministic timestamps and sources. Do not use sleeps.

**Step 2: Run the focused tests and confirm the expected failure**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/TranscriptCorrectionResolverTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests
```

Expected: compilation/test failure because the correction model and resolver do
not exist.

**Step 3: Add the additive SwiftData model**

Implement this storage contract:

```swift
@Model
final class TranscriptCorrectionRecord {
    @Attribute(.unique) var id: UUID
    var anchorStartTime: TimeInterval
    var anchorEndTime: TimeInterval
    var sourceRawValue: String
    var originalText: String
    var replacementText: String
    var transcriptIDsData: Data
    var createdAt: Date
    var updatedAt: Date
    var meeting: MeetingRecord?
}
```

Add a cascade relationship on `MeetingRecord` and include the type in
`MeetingRepository.schema`. All new fields on existing models introduced later
must be optional-backed so an old database opens without destructive migration.

**Step 4: Implement canonical resolution**

Create value types independent from SwiftUI:

```swift
struct CanonicalTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let transcriptIDs: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerID: String?
    let source: TranscriptAudioSource
    let isManuallyEdited: Bool
}

enum TranscriptCorrectionResolver {
    static func resolve(
        transcripts: [TranscriptRecord],
        corrections: [TranscriptCorrectionRecord]
    ) -> [CanonicalTranscriptEntry]
}
```

Resolution order is exact transcript-ID set first, then same-source compatible
time overlap and sequence order. A correction consumes its matched rows once.
If matching is ambiguous, preserve it as one standalone canonical entry at its
stored anchor; never copy it onto multiple rows.

**Step 5: Run focused tests**

Expected: all Task 1 tests pass with zero failures.

**Step 6: Commit**

```bash
git add MeetingNotes/Persistence/Models/TranscriptCorrectionRecord.swift \
  MeetingNotes/Editing/TranscriptCorrectionResolver.swift \
  MeetingNotes/Persistence/Models/MeetingRecord.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/TranscriptCorrectionResolverTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat(editing): persist transcript corrections"
```

### Task 2: Make canonical transcript text survive final replacement

**Files:**

- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`
- Modify: `MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift`

**Step 1: Add failing integration tests**

```swift
func testCorrectionSurvivesReplaceTranscriptsWithNewIDsAndBoundaries()
func testDocumentInputBuilderUsesCanonicalCorrectedText()
func testTranscriptDisplayUsesCanonicalCorrectedText()
func testReplacementCanUpdateTimingAndSpeakerWithoutChangingManualText()
```

The first test must create a correction, call the real
`replaceTranscripts`, and prove that the old generated rows are deleted while
the corrected semantic text remains canonical.

**Step 2: Verify the tests fail for the old raw-text path**

Run the three named test classes with `xcodebuild ... -only-testing:`.
Expected: the summary and display paths still expose `TranscriptRecord.text`.

**Step 3: Add repository correction APIs**

Add narrow methods:

```swift
func saveTranscriptCorrection(
    meetingID: UUID,
    transcriptIDs: [UUID],
    anchorStartTime: TimeInterval,
    anchorEndTime: TimeInterval,
    source: TranscriptAudioSource,
    originalText: String,
    replacementText: String,
    now: Date = .now
) throws

func canonicalTranscripts(meetingID: UUID) throws
    -> [CanonicalTranscriptEntry]
```

`replaceTranscripts` must replace generated rows only. It must not delete or
rewrite correction text. Rebind target IDs when the match is unique; otherwise
leave the independent anchor intact.

**Step 4: Route consumers through the resolver**

- `TranscriptDisplayPolicy` accepts canonical entries instead of reading raw
  generated text directly.
- `MeetingDocumentInputBuilder` resolves corrections before constructing
  `MeetingTranscriptInput`.
- Bookmark excerpts use the same canonical text.

**Step 5: Run focused and speaker-finalizer regressions**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests \
  -only-testing:MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests
```

Expected: zero failures.

**Step 6: Commit**

```bash
git add MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/Summary/MeetingDocumentsUseCase.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingDocumentsUseCaseTests.swift \
  MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift
git commit -m "fix(editing): preserve corrections through finalization"
```

### Task 3: Add meeting revisions and manual document locks

**Files:**

- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/SummaryRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/DetailedMinutesRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentModels.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`

**Step 1: Add failing revision/lock tests**

```swift
func testEditingSummaryMarksManualAndAdvancesMeetingRevision()
func testEditingMinutesMarksManualAndAdvancesMeetingRevision()
func testOrdinaryGenerationCannotOverwriteManualSummary()
func testConfirmedRegenerationCanReplaceManualSummary()
func testGenerationStartedBeforeLaterEditIsRejectedAsStale()
func testLegacyOptionalBackingsResolveToSafeDefaults()
```

**Step 2: Verify failure**

Expected: no meeting-wide revision or manual lock currently exists.

**Step 3: Add optional-backed state**

Add these compatibility properties:

```swift
// MeetingRecord
var contentRevisionBacking: Int?
var notionSyncedContentRevision: Int?
var notionSyncStateRawValue: String?
var notionSyncErrorCode: String?

// SummaryRecord and DetailedMinutesRecord
var isManuallyEditedBacking: Bool?
```

Expose nonoptional computed properties with defaults of revision `0`, sync state
`.localOnly`, and manual edit `false`. Centralize overflow-safe incrementing in
`MeetingContentRevision.next(after:)`.

**Step 4: Add structured edit APIs and stale-write guards**

Add repository APIs accepting complete immutable values:

```swift
func updateSummaryManually(meetingID: UUID, value: GeneratedMeetingSummary) throws
func updateDetailedMinutesManually(meetingID: UUID, value: GeneratedDetailedMinutes) throws
```

Generated-save methods receive the revision observed before awaiting DeepSeek
and `replacingManualEdits: Bool`. They reject a stale revision even after the
user confirmed regeneration, so an edit made while generation is in flight is
never overwritten.

Every canonical payload mutation bumps the meeting revision: title, bookmark,
generated transcript append/replacement, correction, speaker name, summary, and
minutes. A manual document edit also clears its old archive-success state.

**Step 5: Make regeneration intent explicit**

Extend `MeetingDocumentManaging.generate` with
`replacingManualEdits: Bool = false`. The use case captures the meeting revision
before the remote call and passes it to the guarded repository save.

**Step 6: Run focused tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests
git add MeetingNotes/Persistence MeetingNotes/Summary \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingDocumentsUseCaseTests.swift
git commit -m "feat(editing): protect manual meeting documents"
```

### Task 4: Implement current-meeting exact replacement

**Files:**

- Create: `MeetingNotes/Editing/MeetingExactReplacement.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Create: `MeetingNotesTests/MeetingExactReplacementTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Add failing preview and transaction tests**

Test literal occurrence counting and replacement across:

- canonical transcript text;
- speaker display names;
- summary overview/lists/action task and owner;
- minutes overview/section title/content/speakers/decisions/action task and
  owner/open questions.

Also prove:

```swift
func testReplacementNeverTouchesAnotherMeeting()
func testNoMatchDoesNotAdvanceRevision()
func testPersistenceFailureRollsBackEveryTarget()
func testReplacementCreatesCorrectionInsteadOfMutatingGeneratedText()
```

**Step 2: Verify failure**

Run `MeetingExactReplacementTests` and the repository failure test.

**Step 3: Implement the domain operation**

```swift
struct MeetingExactReplacementPreview: Equatable, Sendable {
    let transcriptMatches: Int
    let speakerMatches: Int
    let summaryMatches: Int
    let detailedMinutesMatches: Int
    var totalMatches: Int { /* checked sum */ }
}

@MainActor
final class MeetingExactReplacement {
    func preview(meetingID: UUID, old: String, new: String) throws
        -> MeetingExactReplacementPreview
    func apply(meetingID: UUID, old: String, new: String) throws
        -> MeetingExactReplacementPreview
}
```

Reject an empty old value and an identical old/new pair. Use literal
`String.replacingOccurrences(of:with:)`; do not use regex, fuzzy, locale-aware,
or cross-meeting matching. Save the entire operation atomically and advance the
meeting revision once.

**Step 4: Run tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingExactReplacementTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests
git add MeetingNotes/Editing/MeetingExactReplacement.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/MeetingExactReplacementTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat(editing): replace matching meeting text"
```

### Task 5: Add deterministic automatic local saving

**Files:**

- Create: `MeetingNotes/Editing/MeetingEditAutosaver.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Create: `MeetingNotesTests/MeetingEditAutosaverTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing scheduler tests**

Use an injected suspension seam, not wall-clock sleeps:

```swift
func testRepeatedKeystrokesCoalesceToLatestSnapshot()
func testFlushPersistsImmediatelyAndCancelsPendingDelay()
func testOldSaveCompletionCannotClearNewDirtyDraft()
func testSaveFailureKeepsDraftAndExposesRetryState()
func testMeetingSwitchFlushesOriginalMeetingOnly()
```

**Step 2: Verify failure**

Expected: the view model currently has no edit drafts or save lifecycle.

**Step 3: Implement the autosaver**

Use a generation/token owned on `@MainActor` and an injected async delay:

```swift
enum MeetingLocalSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(message: String)
}

@MainActor
final class MeetingEditAutosaver {
    func schedule(_ save: @escaping @MainActor () throws -> Void)
    func flush() async
    func retry() async
    func cancel()
}
```

The live delay is 350 milliseconds. A completion updates state only when its
generation is still current. `flush()` is used for focus loss, navigation,
window disappearance, and update-restart preflight.

**Step 4: Add view-model draft APIs**

The view model keeps active text fields separate from periodic repository
reloads so the 400 ms live refresh cannot replace in-progress typing. Add
methods to update transcript turns and structured document values, expose local
save state, and expose `flushEdits()`.

**Step 5: Run tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingEditAutosaverTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
git add MeetingNotes/Editing/MeetingEditAutosaver.swift \
  MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotesTests/MeetingEditAutosaverTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat(editing): autosave meeting text"
```

### Task 6: Add inline editing and replacement UI

**Files:**

- Create: `MeetingNotes/Views/MeetingExactReplacementSheet.swift`
- Create: `MeetingNotes/Views/InlineEditableMeetingText.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/App/LaunchArguments.swift`
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Add failing UI-policy and view-model tests**

Prove that inline text changes update the draft immediately, replacement preview
shows target counts, cancellation is a no-op, save errors remain visible, and
manual document regeneration requires explicit confirmation.

Also prove that the normal detail hierarchy remains the original hierarchy:
there is no edit-mode button, Save button, replacement toolbar, or separate
document-editor layout.

Add a UI fixture with one repeated wrong name in all supported areas.

**Step 2: Run the new tests and observe failure**

Use focused unit tests first; then run the single UI test by name.

**Step 3: Implement transcript editing**

- Keep the original transcript row, timecode, speaker badge, padding,
  highlighting, typography, and accessibility grouping.
- Replace only the read-only transcript `Text` with an always-editable,
  borderless multiline native text control styled to render like the original
  text. Do not add an Edit button or edit-mode row.
- Losing focus schedules/flushes without a Save button.
- Speaker editing remains available.
- The floating panel is unchanged.

Keep native accessibility for the editable control and add stable identifiers
for fields and save state without changing the visual hierarchy.

**Step 4: Implement structured document editing**

Modify the existing summary and minutes rendering in place. Replace each
read-only value with `InlineEditableMeetingText` while preserving the existing
card/material, headings, typography, spacing, wrapping, disclosure behavior,
structure, and list order. Cover overview, key points, decisions, action
tasks/owners, bookmark insights, minutes sections, and open questions.

Do not add a separate editor view, boxed form, persistent add/remove controls,
or general rich-text editor. There is no visual transition into an edit mode.

**Step 5: Implement replacement and regeneration confirmation**

- Expose the replacement command from a native context menu on editable text;
  do not add a replacement button or toolbar to the normal detail layout.
- Present old/new text, match count, and affected sections in a compact native
  translucent-material sheet.
- Apply only after confirmation.
- Present a destructive confirmation before replacing a manually edited summary
  or minutes document with generated content.

**Step 6: Flush at lifecycle boundaries**

Call `flushEdits()` when focus leaves, the selected meeting changes, the detail
view disappears, or an update restart is requested. Do not silently cancel a
dirty draft.

Show local save state through the existing lightweight status/error area. Do
not add a permanent save-status toolbar. A failure may expose a native Retry
action; success must not be presented as Notion synchronization.

**Step 7: Run focused UI coverage and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testEditsAutosaveAndReplaceCurrentMeeting
git add MeetingNotes/Views MeetingNotes/App/LaunchArguments.swift \
  MeetingNotesUITests/MeetingFlowUITests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat(ui): edit and correct meeting content"
```

### Task 7: Make Notion synchronization explicit and serialize one canonical page

**Files:**

- Modify: `MeetingNotes/DeepSeek/DeepSeekModels.swift`
- Modify: `MeetingNotes/Notion/NotionBlockBuilder.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentModels.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift`
- Modify: `MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`
- Modify: `MeetingNotesTests/NotionBlockBuilderTests.swift`
- Modify: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`
- Modify: `MeetingNotesTests/SummarizeAndArchiveUseCaseTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Add failing behavior tests**

```swift
func testGenerateNeverArchivesAutomaticallyEvenWhenNotionEnabled()
func testExplicitSyncBuildsSummaryMinutesAndCanonicalTranscriptTogether()
func testPageContentRequiresAtLeastOneLocalDocument()
func testSyncButtonShowsDirtyWhenMeetingRevisionExceedsSyncedRevision()
```

**Step 2: Verify the current auto-archive behavior fails the contract**

Run the four focused suites. Confirm the generation path invokes its archiver
today.

**Step 3: Make snapshot types codable**

Add `Codable` to `MeetingTranscriptInput` and `MeetingBookmarkInput`. Change
`NotionMeetingPageContent` to a codable snapshot that permits summary, minutes,
or both but rejects a snapshot containing neither. It includes the meeting
revision captured at sync start.

**Step 4: Build one canonical page body**

`NotionBlockBuilder.blocks(for:)` emits metadata once, then any available key
summary, detailed minutes, bookmarks, and canonical transcript once. Speaker
labels and edited action owners come from the canonical local snapshot.

**Step 5: Remove automatic Notion writes**

Generation always ends after local persistence. Keep the Notion configuration
toggle as an enable/disable control for the explicit integration, but rename its
description so it no longer promises automatic archiving. Add one explicit
`syncToNotion(meetingID:)` use-case entry point and label the UI button
`同步到 Notion`.

**Step 6: Run tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/NotionBlockBuilderTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesTests/SummarizeAndArchiveUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
git add MeetingNotes/DeepSeek MeetingNotes/Notion/NotionBlockBuilder.swift \
  MeetingNotes/Summary MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift MeetingNotes/Views/SettingsView.swift \
  MeetingNotesTests
git commit -m "feat(notion): sync canonical meeting on demand"
```

### Task 8: Add paginated Notion child-block discovery

**Files:**

- Modify: `MeetingNotes/Notion/NotionModels.swift`
- Modify: `MeetingNotes/Notion/NotionClient.swift`
- Modify: `MeetingNotesTests/NotionClientTests.swift`

**Step 1: Add failing API tests**

```swift
func testListsFirstChildBlockPageWithPageSize100()
func testListsNextPageUsingEncodedCursor()
func testRejectsHasMoreWithoutNextCursor()
func testRejectsBlankOrDuplicateBlockIDs()
```

**Step 2: Verify failure**

Expected: `NotionAPIClient` has no child-listing operation.

**Step 3: Add the protocol and client implementation**

```swift
struct NotionChildBlockPage: Equatable, Sendable {
    let blockIDs: [String]
    let nextCursor: String?
}

protocol NotionAPIClient: Sendable {
    func childBlocks(
        pageID: String,
        startCursor: String?
    ) async throws -> NotionChildBlockPage
    // existing operations remain
}
```

Issue `GET /v1/blocks/{pageID}/children?page_size=100` and include
`start_cursor` only when present. Canonicalize IDs, reject malformed pagination,
and keep Notion tokens out of logs and errors.

**Step 4: Run tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/NotionClientTests
git add MeetingNotes/Notion/NotionModels.swift \
  MeetingNotes/Notion/NotionClient.swift \
  MeetingNotesTests/NotionClientTests.swift
git commit -m "feat(notion): list page blocks safely"
```

### Task 9: Replace the full Notion child page with a resumable checkpoint

**Files:**

- Modify: `MeetingNotes/Notion/NotionModels.swift`
- Modify: `MeetingNotes/Notion/NotionArchiveService.swift`
- Modify: `MeetingNotes/Persistence/Models/ArchiveCheckpointRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotesTests/NotionArchiveServiceTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Add deterministic phase-failure tests**

Cover:

```swift
func testExistingLegacyAndManagedBlocksAreAllCapturedAsOldBlocks()
func testOldBlocksAreNotArchivedUntilEveryNewBatchIsPersisted()
func testPartialAppendFailureRollsBackKnownNewBlocksAndKeepsOldPage()
func testRetryDuringCleanupDoesNotAppendAgain()
func testEditsDuringSyncLeaveMeetingDirtyAfterOldSnapshotCompletes()
func testPaginationLoopOrDuplicateOldIDsStopsBeforeRemoteMutation()
func testCancellationPreservesRecoverableCheckpoint()
```

Fakes must expose barriers between listing, append, checkpoint save, and cleanup;
do not use sleeps.

**Step 2: Verify current behavior fails on untracked legacy blocks**

Run `NotionArchiveServiceTests` and prove a block returned by the live child list
but absent from old local arrays is not currently archived.

**Step 3: Add a whole-page run**

Persist a single optional `NotionPageSyncRun` in the existing checkpoint while
retaining old fields for decode compatibility:

```swift
enum NotionPageSyncPhase: String, Codable, Sendable {
    case appendingNew
    case rollingBackPartialNew
    case cleaningOld
}

struct NotionPageSyncRun: Codable, Equatable, Sendable {
    let contentRevision: Int
    let snapshotData: Data
    var oldBlockIDs: [String]
    var newBlockIDs: [String]
    var nextBatchIndex: Int
    var phase: NotionPageSyncPhase
}
```

Also retain the current successful whole-page block IDs only for diagnostics;
every new sync discovers authoritative old blocks from Notion.

**Step 4: Implement the replacement state machine**

1. Encode and persist the canonical snapshot and complete paginated old-ID list.
2. Append batches and persist returned new IDs after each batch.
3. If a known partial append must be abandoned, archive known new IDs and reset
   the run while leaving every old ID untouched.
4. After all new batches are durable, transition to `cleaningOld`.
5. Archive old IDs one at a time and remove each from the checkpoint.
6. When cleanup is empty, record the snapshot revision as synchronized and
   clear the run.

Never resume a run by rebuilding blocks from newer local content; decode its
stored snapshot. A newer local revision remains dirty after the old snapshot
finishes.

**Step 5: Run Notion and repository tests**

Expected: all existing interruption/cancellation tests and all new whole-page
tests pass.

**Step 6: Commit**

```bash
git add MeetingNotes/Notion MeetingNotes/Persistence \
  MeetingNotesTests/NotionArchiveServiceTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "fix(notion): replace app-managed page content"
```

### Task 10: Add a testable application-update policy

**Files:**

- Create: `MeetingNotes/Updates/UpdateModels.swift`
- Create: `MeetingNotes/Updates/UpdateActivityPolicy.swift`
- Create: `MeetingNotes/Updates/UpdateCoordinator.swift`
- Create: `MeetingNotesTests/UpdateActivityPolicyTests.swift`
- Create: `MeetingNotesTests/UpdateCoordinatorTests.swift`

**Step 1: Add failing domain tests**

```swift
func testPreparingRecordingPausedFinalizingAndArchivingBlockInstallation()
func testReadySummaryReadyArchivedAndIdlePermitInstallation()
func testRepositoryReadFailureBlocksInstallation()
func testAutomaticCheckNeverInstallsWithoutUserAction()
func testBusyInstallRequestIsDeferredWithoutAutomaticRestart()
func testPendingInstallRunsOnlyAfterIdleAndSecondUserAction()
func testPreflightFlushFailurePreventsRestart()
```

**Step 2: Verify failure**

Expected: no update domain types exist.

**Step 3: Define a Sparkle-free driver boundary**

```swift
@MainActor
protocol ApplicationUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
    func installDeferredUpdate()
}

protocol PendingMeetingEditFlushing: AnyObject {
    @MainActor func flushAllEdits() async throws
}
```

`UpdateCoordinator` is `@MainActor @Observable` and owns user-facing state. It
does not import Sparkle. `UpdateActivityPolicy` scans repository meeting states
and fails closed on read errors. It does not modify `MeetingCoordinator` or any
audio implementation.

**Step 4: Implement explicit install semantics**

- Scheduled checks may discover an update but never auto-install it.
- A busy state rejects/defer the install and names the blocker.
- Becoming idle never invokes a stored install handler automatically.
- A second explicit user click flushes all pending edits, rechecks activity, and
  then invokes the deferred handler.

**Step 5: Run tests and commit**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateActivityPolicyTests \
  -only-testing:MeetingNotesTests/UpdateCoordinatorTests
git add MeetingNotes/Updates MeetingNotesTests/UpdateActivityPolicyTests.swift \
  MeetingNotesTests/UpdateCoordinatorTests.swift
git commit -m "feat(updates): gate installation on app activity"
```

### Task 11: Integrate Sparkle 2.9.2 without damaging package references

**Files:**

- Create: `MeetingNotes/Updates/SparkleUpdateDriver.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotes/App/MeetingNotesApp.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`
- Modify: `Configuration/Info.plist`
- Modify: `Configuration/MeetingNotes.entitlements`
- Modify: `project.yml`
- Modify manually: `MeetingNotes.xcodeproj/project.pbxproj`
- Update through package resolution: `MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `MeetingNotesTests/SparkleUpdateConfigurationTests.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: Add failing configuration and adapter tests**

Test that stable and Beta update environments use different HTTPS feeds, UI
testing never starts network checking, and settings expose automatic checks,
manual check, blocker text, and deferred installation.

**Step 2: Add the package declarations manually**

Use `https://github.com/sparkle-project/Sparkle` from `2.9.2`, resolving exactly
to the reviewed stable 2.9.2 revision in `Package.resolved`. Add product
`Sparkle` to the application target.

Update `project.yml` to describe all three direct packages: ArgmaxOSS,
FluidAudio, and Sparkle. Do **not** generate the project. Manually add only the
Sparkle build file, remote package reference, product dependency, framework
phase entry, project package entry, and target product entry to `project.pbxproj`.

Immediately verify:

```bash
rg -n 'WhisperKit|FluidAudio|Sparkle' MeetingNotes.xcodeproj/project.pbxproj
git diff -- MeetingNotes.xcodeproj/project.pbxproj
```

Expected: FluidAudio and WhisperKit are unchanged and Sparkle is additive.

**Step 3: Configure sandboxed Sparkle**

Add these Info keys using per-configuration build settings where necessary:

```text
SUFeedURL
SUPublicEDKey
SUEnableAutomaticChecks = true
SUAutomaticallyUpdate = false
SUEnableInstallerLauncherService = true
```

Add the official installer-service temporary Mach lookup names to the existing
sandbox entitlements:

```text
$(PRODUCT_BUNDLE_IDENTIFIER)-spks
$(PRODUCT_BUNDLE_IDENTIFIER)-spki
```

Keep the existing sandbox, audio-input, and network-client entitlements.
Production uses the stable feed; Beta uses the Beta feed. Debug/UI testing uses
an injected inert driver and does not contact GitHub.

**Step 4: Establish the EdDSA manual credential gate**

Download the official Sparkle 2.9.2 distribution tools and verify the release
artifact before use. Run `generate_keys` only after confirming where the private
key will be backed up. Commit only the printed public key. If exporting for CI,
use `generate_keys -x` to a protected temporary location and transfer it to the
GitHub secret; never stage or print it.

If that authorization or secure destination is unavailable, stop with the
updater compiled against a non-release test configuration and report the release
blocker. Do not commit a placeholder public key as if it were valid.

**Step 5: Implement the live adapter**

Wrap `SPUStandardUpdaterController` in `SparkleUpdateDriver`. Use
`SPUUpdaterDelegate` to report discovery/errors and
`shouldPostponeRelaunchForUpdate` to retain an install handler when activity
becomes protected after download. The retained handler is invoked only from the
next user action after activity and edit-flush checks pass.

**Step 6: Wire settings and commands**

Expose **About and Updates** with current version/channel, automatic-check
toggle, **Check for Updates**, blocker text, and **Update and Restart** when the
driver reports an available/deferred update. Sparkle's standard update window
continues to present signed release notes and progress.

**Step 7: Build and run focused tests**

```bash
xcodebuild -resolvePackageDependencies \
  -project MeetingNotes.xcodeproj -scheme MeetingNotes
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateCoordinatorTests \
  -only-testing:MeetingNotesTests/SparkleUpdateConfigurationTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests
```

Expected: exit 0, no package-reference removal, no network call in tests.

**Step 8: Commit**

```bash
git add MeetingNotes/Updates MeetingNotes/App MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotes/Views/SettingsView.swift Configuration project.yml \
  MeetingNotes.xcodeproj/project.pbxproj \
  MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  MeetingNotesTests/SparkleUpdateConfigurationTests.swift \
  MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "feat(updates): integrate signed Sparkle updates"
```

### Task 12: Add guarded GitHub release and appcast tooling

**Files:**

- Create: `Scripts/validate_update_release.sh`
- Modify: `Scripts/build_and_package.sh`
- Create: `.github/workflows/publish-update.yml`
- Create: `docs/releasing/in-app-updates.md`
- Create: `MeetingNotesTests/UpdateReleasePolicyTests.swift`

**Step 1: Write failing release-policy tests**

Parse configuration and workflow text to prove:

- a normal branch push is not a release trigger;
- Beta publishes only to the Beta feed and a GitHub prerelease;
- stable publishes only to the stable feed and a non-prerelease;
- missing Developer ID, notarization, EdDSA, or expected identity stops before
  appcast publication;
- the Sparkle private key is read from stdin/secret and never written beneath
  the repository.

**Step 2: Verify failure**

Expected: the workflow and validator do not exist.

**Step 3: Add local validation**

`validate_update_release.sh` accepts configuration, artifact, expected version,
build, bundle ID, feed, and public key. It verifies:

- mounted app identity and privacy string;
- `codesign --verify --deep --strict`;
- Developer ID authority, secure timestamp, hardened runtime, and nested Sparkle
  helpers;
- sandbox/audio-input/network-client/Sparkle Mach lookup entitlements;
- `spctl`, notarization/stapling, DMG verification, SHA-256;
- appcast enclosure URL, byte length, build version, short version, EdDSA
  signature, arm64 requirement, and correct channel/feed.

Ad-hoc packaging may still be used for local feature smoke, but this validator
must label it non-publishable and exit nonzero for the release path.

**Step 4: Add a manually dispatched release workflow**

The workflow is `workflow_dispatch` only. It imports a Developer ID certificate
into a temporary keychain, creates a temporary notarytool profile, builds and
notarizes, generates the appcast with Sparkle 2.9.2, validates it, creates the
appropriate GitHub Release, and updates only the selected GitHub Pages feed.

Required protected secrets:

```text
DEVELOPER_ID_P12_BASE64
DEVELOPER_ID_P12_PASSWORD
DEVELOPMENT_TEAM
APPLE_NOTARY_KEY_ID
APPLE_NOTARY_ISSUER_ID
APPLE_NOTARY_PRIVATE_KEY
SPARKLE_ED_PRIVATE_KEY
```

Feed signing uses stdin, equivalent to:

```bash
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | \
  generate_appcast --ed-key-file - <updates-directory>
```

Never use `pull_request` or ordinary `push` as a publishing trigger. The action
must finish validation before mutating a Release or feed.

**Step 5: Document the one-time bootstrap**

Document that the first updater-enabled app still requires manual DMG
installation, how to back up/rotate the EdDSA key, configure Developer ID and
notary secrets, publish Beta versus stable, revoke a bad feed item, and fall back
to the GitHub Release page.

**Step 6: Validate scripts and commit**

```bash
bash -n Scripts/build_and_package.sh
bash -n Scripts/validate_update_release.sh
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/UpdateReleasePolicyTests
git diff --check
git add Scripts .github/workflows/publish-update.yml \
  docs/releasing/in-app-updates.md \
  MeetingNotesTests/UpdateReleasePolicyTests.swift
git commit -m "build(release): add guarded GitHub update publishing"
```

### Task 13: Run complete validation and prepare the next Beta gate

**Files:**

- Modify only at the release gate: `project.yml`
- Modify only at the release gate: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify only at the release gate: `Scripts/build_and_package.sh`
- Update: `docs/testing/` with the exact acceptance record

**Step 1: Audit before version changes**

```bash
git status --short
git diff --check
git diff --stat HEAD~12..HEAD
git diff HEAD~12..HEAD -- MeetingNotes.xcodeproj/project.pbxproj
```

Confirm no audio/model behavior changed and all package references remain.

**Step 2: Run focused suites**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/TranscriptCorrectionResolverTests \
  -only-testing:MeetingNotesTests/MeetingExactReplacementTests \
  -only-testing:MeetingNotesTests/MeetingEditAutosaverTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesTests/NotionBlockBuilderTests \
  -only-testing:MeetingNotesTests/NotionClientTests \
  -only-testing:MeetingNotesTests/NotionArchiveServiceTests \
  -only-testing:MeetingNotesTests/UpdateActivityPolicyTests \
  -only-testing:MeetingNotesTests/UpdateCoordinatorTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  -only-testing:MeetingNotesTests/AdaptiveMicrophoneSampleProviderTests \
  -only-testing:MeetingNotesTests/AudioDiagnosticCoordinatorTests
```

Expected: zero failures.

**Step 3: Run build, full units, and whole scheme**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS' build
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test -only-testing:MeetingNotesTests
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS' test
```

Record exact counts and exit codes; do not hide UI or environment failures.

**Step 4: Ask for the release version/build gate**

The current Beta is `1.2.0 (13)`. Before editing version metadata, confirm the
next marketing version and build with the user. If the user keeps the current
series, increment only Beta to `1.2.0 (14)` and keep production exactly
`1.1.1 (3)`. Update the three version sources manually; do not regenerate the
project.

**Step 5: Package without overclaiming distribution**

Run `./Scripts/build_and_package.sh Beta`. If Developer ID/notarization is not
configured, label the DMG as local-testing only and do not publish an appcast.
If it is configured, run `validate_update_release.sh` and record the exact DMG
path, size, SHA-256, mounted identity, entitlements, code signature,
notarization, and appcast signature.

**Step 6: Perform packaged-app human acceptance**

Using the actual packaged app, verify:

- live transcript edits auto-save and survive meeting finalization/restart;
- summary and minutes edits survive ordinary app actions;
- exact replacement affects only the current meeting;
- explicit Notion sync replaces the page without permanent duplication;
- update checking finds only the expected channel;
- protected meeting/sync activity blocks installation;
- an idle explicit update restarts and preserves local meetings/settings.

Automated tests cannot mark these human checks as passed.

**Step 7: Final source audit and handoff**

Run `git diff --check`, inspect status and commits, and report any remaining
Developer ID, notarization, clean-Mac, or GitHub secret gate. Do not push,
publish a Release, update a PR, or merge without the user's explicit instruction.

## Completion definition

The implementation is complete only when manual corrections survive automatic
transcript replacement, structured documents auto-save safely, Notion converges
to one canonical whole-page snapshot after retry, stable/Beta update feeds are
isolated, protected activity cannot be interrupted by installation, all
deterministic tests pass, and the actual signed packaged-app update path passes
human validation on a second build. FluidAudio tuning and timeline notes or
screenshots remain separate follow-up work.
