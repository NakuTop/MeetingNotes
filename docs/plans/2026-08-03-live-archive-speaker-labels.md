# Live Archive Status, Recording Timer, and Speaker Labels Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Notion archive indicators reflect the selected archived document, show an accurate live recording timer, and add reusable user-defined speaker names that propagate through transcripts and future generated meeting documents.

**Architecture:** Add pure display and matching policies around the existing persisted archive and speaker IDs. Keep recording duration authoritative in `ActiveRecordingTimeline`, but mirror lifecycle transitions into a shared observable presentation store for one-second UI updates without database churn. Persist meeting-scoped speaker assignments in SwiftData and global name suggestions in `AppSettingsStore`; resolve names at display and document-input boundaries instead of copying them into every transcript.

**Tech Stack:** Swift 6, SwiftUI Observation and `TimelineView`, SwiftData, FluidAudio diarization output, UserDefaults, XCTest, XCUITest, and Xcode arm64 Release builds.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/speaker-aware-transcription` on branch `codex/speaker-aware-transcription`.
- Use `@test-driven-development` for every production change: add one focused failing test, observe the expected failure, implement the minimum behavior, and rerun it green.
- Use `@systematic-debugging` for unexpected failures; do not stack speculative fixes.
- Do not delegate debugging or design work to DeepSeek.
- Do not modify, delete, or stage existing untracked `.deriveddata-*` or `.sandbox-*` directories.
- Do not build a DMG, push GitHub, or replace `/Applications/MeetingNotes.app`.
- Use `@verification-before-completion` and `@code-reviewer` before claiming completion.

## Shared focused-test command

Use a fresh derived-data directory per task:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-taskN \
  -only-testing:MeetingNotesTests/<TestClass>/<testMethod>
```

Expected successful focused runs end with `** TEST SUCCEEDED **`.

### Task 1: Derive a three-state Notion archive indicator

**Files:**

- Create: `MeetingNotes/Views/MeetingNotionArchiveDisplayState.swift`
- Create: `MeetingNotesTests/MeetingNotionArchiveDisplayStateTests.swift`
- Modify: `MeetingNotes/Views/MeetingSidebarView.swift:130-181`

**Step 1: Write the failing state-policy tests**

Cover no archived documents, one archived plus one local document, all existing documents archived, one archived document with the other type absent, and legacy archived meetings that have a Notion page but no current document records:

```swift
func testDetailedMinutesArchiveMakesMixedMeetingPartiallyArchived() {
    XCTAssertEqual(
        MeetingNotionArchiveDisplayState.resolve(
            summary: .localOnly,
            detailedMinutes: .archived,
            legacyMeetingState: .summaryReady,
            hasNotionPage: true
        ),
        .partial
    )
}

func testSingleExistingArchivedDocumentIsComplete() {
    XCTAssertEqual(
        MeetingNotionArchiveDisplayState.resolve(
            summary: nil,
            detailedMinutes: .archived,
            legacyMeetingState: .summaryReady,
            hasNotionPage: true
        ),
        .complete
    )
}
```

Assert the exact symbol and accessibility text contract:

- `.none`: `icloud.slash`, `未归档到 Notion`
- `.partial`: `checkmark.icloud`, `部分内容已归档到 Notion`
- `.complete`: `checkmark.icloud.fill`, `全部内容已归档到 Notion`

**Step 2: Run the policy suite and verify red**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-task1 \
  -only-testing:MeetingNotesTests/MeetingNotionArchiveDisplayStateTests
```

Expected: compile failure because `MeetingNotionArchiveDisplayState` does not exist.

**Step 3: Implement the pure state resolver**

Create:

```swift
enum MeetingNotionArchiveDisplayState: Equatable, Sendable {
    case none
    case partial
    case complete

    static func resolve(
        summary: MeetingDocumentArchiveState?,
        detailedMinutes: MeetingDocumentArchiveState?,
        legacyMeetingState: RecordingState,
        hasNotionPage: Bool
    ) -> Self {
        let states = [summary, detailedMinutes].compactMap { $0 }
        guard !states.isEmpty else {
            return legacyMeetingState == .archived && hasNotionPage
                ? .complete
                : .none
        }
        let archivedCount = states.filter { $0 == .archived }.count
        if archivedCount == 0 { return .none }
        return archivedCount == states.count ? .complete : .partial
    }
}
```

Add `symbolName` and `accessibilityLabel` properties with the strings above.

**Step 4: Render the derived state in the sidebar**

Replace every `meeting.state == .archived` archive-icon check in `MeetingHistoryRow`
with one locally derived state. Use secondary color for `.none`, blue for `.partial`,
and green for `.complete`. Build the combined accessibility label from the same
`accessibilityLabel` property.

**Step 5: Run tests and validate symbols**

Run the task suite again, then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-task1 \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: PASS; `NSImage(systemSymbolName:)` assertions prove all three symbols exist.

**Step 6: Commit**

```bash
git add MeetingNotes/Views/MeetingNotionArchiveDisplayState.swift \
  MeetingNotes/Views/MeetingSidebarView.swift \
  MeetingNotesTests/MeetingNotionArchiveDisplayStateTests.swift
git commit -m "fix: reflect partial Notion archive status"
```

### Task 2: Persist and edit the global frequent-speaker name library

**Files:**

- Modify: `MeetingNotes/Settings/AppSettingsStore.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift:180-370`
- Modify: `MeetingNotes/Views/SettingsView.swift:140-270`
- Modify: `MeetingNotesTests/AppSettingsStoreTests.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: Write failing normalization and persistence tests**

Add tests proving that names survive a new store instance, whitespace is trimmed,
case-insensitive duplicates are removed, empty strings are ignored, and names longer
than 40 characters are rejected:

```swift
store.frequentSpeakerNames = [" 张三 ", "张三", "ALICE", "alice", ""]
XCTAssertEqual(store.frequentSpeakerNames, ["张三", "ALICE"])

store.rememberSpeakerName(" 李四 ")
XCTAssertEqual(
    AppSettingsStore(defaults: defaults).frequentSpeakerNames,
    ["张三", "ALICE", "李四"]
)
```

Add view-model tests for `load()`, adding a valid draft, ignoring a duplicate, removing
a name, and `save()` persisting the current ordered draft.

**Step 2: Run the two focused suites and verify red**

Expected: compile failures for the missing properties and editing methods.

**Step 3: Implement the store contract**

Add key `settings.frequentSpeakerNames`, an observable `[String]` property, and:

```swift
static func normalizedSpeakerNames(_ names: [String]) -> [String]
func rememberSpeakerName(_ name: String)
```

Normalization must trim whitespace/newlines, require `1...40` characters, preserve
input order, and deduplicate with `localizedCaseInsensitiveCompare` semantics.

**Step 4: Implement the settings draft and UI**

Add to `SettingsViewModel`:

```swift
var frequentSpeakerNames: [String] = []
var newSpeakerName = ""
func addFrequentSpeakerName()
func removeFrequentSpeakerName(_ name: String)
```

`load()` copies from the store and clears the input. `save()` writes the normalized
array with the other settings. Add an `AdaptiveGlassCard` titled `常用说话人` with a
text field, `添加` button, compact removable chips, explanatory text, and accessibility
identifiers `settings.speakers.newName`, `settings.speakers.add`, and
`settings.speakers.name.<index>`.

**Step 5: Run store and view-model suites green, then build**

Expected: both suites pass and the app target compiles.

**Step 6: Commit**

```bash
git add MeetingNotes/Settings/AppSettingsStore.swift \
  MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotes/Views/SettingsView.swift \
  MeetingNotesTests/AppSettingsStoreTests.swift \
  MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "feat: add frequent speaker name settings"
```

### Task 3: Persist one custom name per meeting speaker ID

**Files:**

- Create: `MeetingNotes/Persistence/Models/SpeakerNameRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift:20-60`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift:20-45,145-235`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write failing repository tests**

Create a meeting with two transcript rows sharing `room-1` and one `room-2`. Test:

```swift
try repository.setSpeakerDisplayName(
    meetingID: meetingID,
    speakerID: "room-1",
    displayName: " 张三 "
)
XCTAssertEqual(
    try repository.speakerDisplayNames(meetingID: meetingID),
    ["room-1": "张三"]
)
```

Then rename `room-1` again and assert only one assignment exists, clear it and assert
the default mapping is empty, reject a missing speaker ID, and delete the meeting to
prove assignment records cascade-delete. Add a save-failure test proving an existing
assignment is restored exactly.

**Step 2: Run focused repository tests and verify red**

Expected: compile failures for the missing model and repository methods.

**Step 3: Add the SwiftData model and relationship**

Create a `@Model final class SpeakerNameRecord` with `id`, `speakerID`, `displayName`,
`evidenceStartTime`, `evidenceEndTime`, `createdAt`, `updatedAt`, and inverse optional
`meeting`. Add a cascade relationship `speakerNames` to `MeetingRecord` and include
the model in `MeetingRepository.schema`.

**Step 4: Implement transactional repository operations**

Add:

```swift
func speakerDisplayNames(meetingID: UUID) throws -> [String: String]
func setSpeakerDisplayName(
    meetingID: UUID,
    speakerID: String,
    displayName: String,
    now: Date = .now
) throws
func clearSpeakerDisplayName(meetingID: UUID, speakerID: String) throws
```

Use the normalized 40-character policy from Task 2. Derive evidence bounds from the
meeting's current transcripts carrying that speaker ID. Update the existing record or
insert one new record, update `meeting.updatedAt`, and restore/delete the mutation if
`saveContext()` fails.

**Step 5: Run `MeetingRepositoryTests` green**

Expected: all existing transcript replacement and deletion rollback tests remain green.

**Step 6: Commit**

```bash
git add MeetingNotes/Persistence/Models/SpeakerNameRecord.swift \
  MeetingNotes/Persistence/Models/MeetingRecord.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: persist meeting speaker names"
```

### Task 4: Resolve custom names in transcripts and generated documents

**Files:**

- Modify: `MeetingNotes/Transcription/TranscriptSpeakerLabelPolicy.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift:590-625`
- Modify: `MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift`
- Modify: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`

**Step 1: Write failing resolver tests**

Add tests proving custom names override the default rule, an empty custom value falls
back to the default label, and unrelated IDs retain current behavior:

```swift
XCTAssertEqual(
    TranscriptSpeakerLabelPolicy.label(
        speakerID: "remote-2",
        source: .system,
        customNames: ["remote-2": "王老师"]
    ),
    "王老师"
)
```

Add a `MeetingDocumentInputBuilder` test with two transcripts sharing `room-1` and
assert both generated inputs carry `张三`, while `room-2` still carries `说话人 2`.

**Step 2: Run both suites and verify red**

Expected: the new overload and custom mapping are unavailable.

**Step 3: Add one shared resolution path**

Extend `TranscriptSpeakerLabelPolicy.label` with a defaulted
`customNames: [String: String] = [:]`. Resolve a nonempty exact-ID custom name first,
then execute the existing semantic switch unchanged.

Add a `MeetingRecord.speakerDisplayNames` computed dictionary from its assignment
relationship, using deterministic conflict resolution by latest `updatedAt` for any
legacy duplicates.

Pass this dictionary into `MeetingDocumentInputBuilder` and the transcript badge
policy. Do not put user-facing names into `TranscriptRecord.speakerID`.

**Step 4: Run resolver, document, DeepSeek, and detailed-minutes tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-task4 \
  -only-testing:MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesTests/DeepSeekClientTests \
  -only-testing:MeetingNotesTests/DetailedMinutesPromptTests
```

Expected: PASS and no payload schema changes other than the resolved label string.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptSpeakerLabelPolicy.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotes/Summary/MeetingDocumentsUseCase.swift \
  MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift \
  MeetingNotesTests/MeetingDocumentsUseCaseTests.swift
git commit -m "feat: resolve custom speaker names everywhere"
```

### Task 5: Group transcript turns and add the speaker rename interaction

**Files:**

- Create: `MeetingNotes/Views/SpeakerNameEditor.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift:95-130`
- Modify: `MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing turn-grouping tests**

Define `TranscriptDisplayTurn` and test that two adjacent `room-1` entries no more than
five seconds apart become one turn; a speaker change, larger gap, nil speaker ID, or
bookmark-highlight boundary starts a new turn. Assert the grouped turn retains ordered
transcript IDs and joins cleaned text without changing source records.

**Step 2: Write failing rename view-model tests**

Construct a diarized meeting and assert:

```swift
XCTAssertTrue(viewModel.renameSpeaker("room-1", to: "张三"))
XCTAssertEqual(viewModel.speakerDisplayNames["room-1"], "张三")
XCTAssertTrue(settingsStore.frequentSpeakerNames.contains("张三"))
```

Also test clearing to the generated default, invalid blank or oversized names, and a
repository save failure producing a short visible error without mutating history.

**Step 3: Run both suites and verify red**

Expected: missing turn grouping and rename API failures.

**Step 4: Implement presentation-only turn grouping**

Keep `TranscriptDisplayEntry` as the sanitized leaf value. Add a pure
`TranscriptDisplayPolicy.turns(from:bookmarks:)` that only groups entries when:

- both carry the same nonnil `speakerID` and source;
- the next start is at most five seconds after the current end;
- both have the same bookmark-highlight result.

The UI renders a single timestamp and speaker button at the start of each turn, while
retaining original transcript IDs for identity and accessibility.

**Step 5: Implement speaker chips and editing**

At the top of `TranscriptView`, derive unique speaker options by first appearance.
Render compact buttons using the existing palette. Clicking a chip or turn badge opens
`SpeakerNameEditor`, which contains a text field, frequent-name suggestion buttons,
`保存`, `恢复默认`, and `取消`.

Pass callbacks from `MeetingDetailView` into `MeetingDetailViewModel.renameSpeaker`
and `clearSpeakerName`. After a successful repository save, remember the name in
`AppSettingsStore`, reload the meeting, and make every matching turn update in one UI
refresh. Use `meeting.transcripts.speaker.<speakerID>` accessibility identifiers.

**Step 6: Run view-model and transcript suites green, then build**

Expected: PASS and no changes to stored transcript text, sequence, or bookmark data.

**Step 7: Commit**

```bash
git add MeetingNotes/Views/SpeakerNameEditor.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: rename and group meeting speakers"
```

### Task 6: Restore reliable names after re-running diarization

**Files:**

- Create: `MeetingNotes/Diarization/SpeakerNameRemapper.swift`
- Create: `MeetingNotesTests/SpeakerNameRemapperTests.swift`
- Modify: `MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift:899-947`
- Modify: `MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write failing pure remapper tests**

Use old named speaker segments and new attributed drafts to cover:

- exact high-overlap `room-1 -> room-2` migration;
- two old speakers mapping uniquely to two new IDs;
- best coverage below `0.60` returns no name;
- winner margin below `0.15` returns no name;
- two old names competing for one new ID remain unnamed rather than guessing;
- online microphone `me` exact identity remains eligible without confusing system audio.

The public result is `[newSpeakerID: displayName]` and must be deterministic regardless
of dictionary order.

**Step 2: Run the remapper suite and verify red**

Expected: compile failure because `SpeakerNameRemapper` does not exist.

**Step 3: Implement overlap scoring**

For each old custom speaker, sum intersections between its old transcript intervals and
each new speaker's intervals. Divide by total positive old-speaker duration. Accept only
a unique winner with coverage at least `0.60` and a margin of at least `0.15` over the
runner-up. Resolve global collisions conservatively: if two accepted old speakers select
the same new ID, remove that new-ID assignment.

**Step 4: Write failing repository atomic-replacement tests**

Extend `completeSpeakerDiarizationRetry` to accept `speakerDisplayNames: [String:String]`.
Test that transcript rows and speaker assignments are replaced together. Force
`contextSaver` failure and assert both the original transcripts and original names remain.

**Step 5: Wire the retry use case**

Before diarization, capture current final transcripts and `meeting.speakerDisplayNames`.
After producing drafts, run the remapper and pass the migrated names into the repository's
single transaction. When there were no custom names, behavior and current error codes
remain unchanged.

**Step 6: Run remapper, retry, and repository suites green**

Expected: reliable migrations persist; ambiguous matches keep generated labels; all
existing cancellation and rollback tests pass.

**Step 7: Commit**

```bash
git add MeetingNotes/Diarization/SpeakerNameRemapper.swift \
  MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/SpeakerNameRemapperTests.swift \
  MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: preserve speaker names across diarization"
```

### Task 7: Build the shared recording-session presentation clock

**Files:**

- Create: `MeetingNotes/Recording/RecordingSessionPresentationStore.swift`
- Create: `MeetingNotesTests/RecordingSessionPresentationStoreTests.swift`

**Step 1: Write failing deterministic clock tests**

Use explicit monotonic values:

```swift
let store = RecordingSessionPresentationStore()
store.start(meetingID: id, monotonicTime: 100)
XCTAssertEqual(store.activeDuration(for: id, at: 103.4), 3.4)

store.pause(meetingID: id, activeDuration: 3.4)
XCTAssertEqual(store.activeDuration(for: id, at: 200), 3.4)

store.resume(meetingID: id, activeDuration: 3.4, monotonicTime: 200)
XCTAssertEqual(store.activeDuration(for: id, at: 203), 6.4)
```

Also assert another meeting returns `nil`, stale transitions for an old meeting are
ignored, and `finish` freezes the final duration until `clear`.

**Step 2: Run the suite and verify red**

Expected: compile failure for the missing store.

**Step 3: Implement the observable store and update protocol**

Create a `@MainActor @Observable final class RecordingSessionPresentationStore` and a
`RecordingSessionPresentationUpdating: Sendable` protocol with async lifecycle methods.
The store holds only meeting ID, phase, accumulated active duration, and resume monotonic
anchor. Clamp invalid or negative values to zero and never read wall-clock `Date`.

Provide a no-op implementation as the default dependency for isolated coordinator tests.

**Step 4: Run the deterministic suite green**

Expected: exact durations pass without sleeps or real timers.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording/RecordingSessionPresentationStore.swift \
  MeetingNotesTests/RecordingSessionPresentationStoreTests.swift
git commit -m "feat: add live recording presentation clock"
```

### Task 8: Wire accurate recording time into the coordinator and both UIs

**Files:**

- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift:206-260,520-575`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift:165-390`
- Modify: `MeetingNotes/App/AppContainer.swift:1-170,320-345`
- Modify: `MeetingNotes/App/LaunchArguments.swift:205-235`
- Modify: `MeetingNotes/FloatingPanel/FloatingRecorderView.swift`
- Modify: `MeetingNotes/FloatingPanel/FloatingPanelController.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift:180-235,375-410`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`
- Modify: `MeetingNotesTests/FloatingControlTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing coordinator lifecycle tests**

Inject a recording-presentation spy and the existing manual monotonic clock. Assert exact
events and durations for start at `100`, pause at `105`, resume at `205`, and stop at
`208`: `start(100)`, `pause(5)`, `resume(active:5, at:205)`, `finish(8)`. Add a start
failure test proving no active presentation remains.

**Step 2: Run focused coordinator tests and verify red**

Expected: the dependency and lifecycle callbacks do not yet exist.

**Step 3: Wire lifecycle updates without changing authority**

Add `recordingPresentation` to `MeetingCoordinatorDependencies`, defaulting to the no-op
implementation. Call it only after successful lifecycle transitions. Derive pause, resume,
and finish values from the same `ActiveRecordingTimeline` and monotonic timestamps already
used for bookmarks and final persistence.

Create one shared live store in `AppContainer`, pass it to live/custom coordinator
dependencies, `FloatingPanelController`, and every `MeetingDetailViewModel`.

**Step 4: Write failing view-model and floating presentation tests**

Assert that a detail view model returns live duration only for its own active meeting and
falls back to persisted `activeDuration` for another meeting. Assert floating elapsed text
uses monospaced `00:00`, changes with explicit store time, and paused presentation is marked
paused. Keep the four controls in their existing order.

**Step 5: Implement `TimelineView` rendering**

In the detail header and active audio card, replace direct `meeting.activeDuration` reads
with a small `TimelineView(.periodic(from: .now, by: 1))`. On each tick, use
`ProcessInfo.processInfo.systemUptime` only as the redraw sample passed into the store.

Add the same timer to the floating capsule, expand its width to fit without hiding the four
controls, use `.monospacedDigit()`, and add accessibility identifier `floating.elapsed`.
Add a red pulse while recording and a fixed orange paused indicator. Gate pulse animation
with `accessibilityReduceMotion`.

**Step 6: Run coordinator, view-model, and floating suites green**

Then run all `MeetingCoordinatorTests` to prove capture, pause, retry, finalization, and
error ordering remain intact.

**Step 7: Commit**

```bash
git add MeetingNotes/Recording/RecordingSessionPresentationStore.swift \
  MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift \
  MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotes/App/AppContainer.swift MeetingNotes/App/LaunchArguments.swift \
  MeetingNotes/FloatingPanel/FloatingRecorderView.swift \
  MeetingNotes/FloatingPanel/FloatingPanelController.swift \
  MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift \
  MeetingNotesTests/FloatingControlTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: show accurate live recording time"
```

### Task 9: UI acceptance fixtures and regression verification

**Files:**

- Modify: `MeetingNotes/App/LaunchArguments.swift`
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift`
- Modify tests or production files only for a test-first regression fix discovered here.

**Step 1: Add deterministic UI fixtures**

Extend the UI-test seed with a meeting containing `room-1`, `room-2`, repeated adjacent
turns, one saved custom name, and two frequent names. Add a partial-Notion fixture with
summary `.localOnly` and detailed minutes `.archived`. Do not include real API keys,
meeting content, or user data.

**Step 2: Add UI acceptance tests**

Cover:

- partial archive history row announces `部分内容已归档到 Notion`;
- speaker chips appear once per speaker;
- selecting a historical name and saving updates every matching visible turn;
- settings can add and remove a frequent name;
- the existing recording fixture exposes a changing `floating.elapsed` value without
  relying on a fixed one-second sleep longer than necessary.

**Step 3: Run the new UI tests**

Expected: PASS with stable identifiers and no external network access.

**Step 4: Run all unit tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-unit \
  -only-testing:MeetingNotesTests
```

Expected: every unit test passes.

**Step 5: Run all UI tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-ui \
  -only-testing:MeetingNotesUITests
```

Expected: every UI test passes.

**Step 6: Build arm64 Release**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-live-speakers-release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: `** BUILD SUCCEEDED **`.

**Step 7: Re-sign and inspect entitlements**

Re-sign the Release app using `Configuration/MeetingNotes.entitlements`. Verify
`codesign --verify --deep --strict` succeeds and `codesign -d --entitlements :-` does
not contain `get-task-allow`.

**Step 8: Replace only the local test app**

Quit `/Users/shenminghao/Applications/MeetingNotes 测试版.app`, replace it with the
verified Release app using `ditto`, and reopen it. Do not touch
`/Applications/MeetingNotes.app`.

**Step 9: Final review and status check**

Run `git diff --check`, inspect `git status --short`, review all changes against the
approved design, and confirm only pre-existing untracked build/sandbox directories remain.

**Step 10: Commit UI fixtures if changed**

```bash
git add MeetingNotes/App/LaunchArguments.swift \
  MeetingNotesUITests/MeetingFlowUITests.swift
git commit -m "test: cover speaker labels and live archive status"
```
