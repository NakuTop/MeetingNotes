# Meeting Library, Transcription, Permissions, and Playback Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add native meeting management, bilingual clean transcription, reusable recording sessions, recoverable screen-recording permission, synchronized Notion renaming, and an in-app draggable waveform player for local recordings.

**Architecture:** Keep SwiftData as the source of truth for meeting metadata, introduce one shared title-update use case for local/Notion consistency, and make the coordinator reusable by resetting only after a successful finalize. Build playback from the existing CAF segment manifest through a virtual AVFoundation composition, with a cached background waveform analyzer and one shared playback controller so deletion and navigation can release resources safely.

**Tech Stack:** Swift 6, SwiftUI/Observation, SwiftData, AVFoundation, ScreenCaptureKit/CoreGraphics TCC APIs, WhisperKit 1.0.0, URLSession, XCTest/XCUITest, macOS 15–26, Apple Silicon arm64.

---

Work from:

```bash
cd "/Users/shenminghao/Documents/会议记录app/.worktrees/codex/native-meeting-notes"
```

Use this unit-test command pattern throughout:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/<TestClass>
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so newly created Swift files under `MeetingNotes`, `MeetingNotesTests`, and `MeetingNotesUITests` are discovered automatically. Do not hand-edit `project.pbxproj` for file references.

### Task 1: Persist pin state and centralize meeting ordering

**Files:**
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`

**Step 1: Write the failing repository tests**

Add tests that create three meetings at deterministic dates, pin two at different deterministic dates, and assert the exact order. Also assert that unpinning returns the meeting to the normal start-date order and that an existing record defaults to unpinned.

```swift
func testMeetingsSortPinnedByMostRecentPinThenUnpinnedByStartDate() throws {
    let repository = try MeetingRepository.inMemory()
    let oldID = try repository.createMeeting(mode: .offline, startedAt: date(1))
    let newID = try repository.createMeeting(mode: .offline, startedAt: date(3))
    let middleID = try repository.createMeeting(mode: .online, startedAt: date(2))

    try repository.setPinned(meetingID: oldID, pinnedAt: date(10))
    try repository.setPinned(meetingID: middleID, pinnedAt: date(11))

    XCTAssertEqual(try repository.meetings().map(\.id), [middleID, oldID, newID])
}

func testUnpinRestoresStartedAtOrdering() throws {
    // Pin, unpin with nil, then expect normal descending start date.
}
```

Add a Library ViewModel test proving `load()` preserves repository ordering instead of re-sorting by `startedAt`.

**Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: compile failure because `MeetingRecord.pinnedAt` and `setPinned` do not exist, followed by the ViewModel ordering test failing against its local `startedAt` sort.

**Step 3: Implement the smallest persistent model and ordering policy**

Add to `MeetingRecord`:

```swift
var pinnedAt: Date?

var isPinned: Bool { pinnedAt != nil }
```

Add an optional `pinnedAt: Date? = nil` initializer argument so existing call sites remain source compatible. In `MeetingRepository`, add:

```swift
func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
    let meeting = try meeting(id: meetingID)
    meeting.pinnedAt = pinnedAt
    meeting.updatedAt = .now
    try context.save()
}

private static func ordered(_ lhs: MeetingRecord, _ rhs: MeetingRecord) -> Bool {
    switch (lhs.pinnedAt, rhs.pinnedAt) {
    case let (left?, right?) where left != right:
        return left > right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
```

Fetch records, then apply this deterministic comparator. Extend `MeetingLibraryRepository` with `setPinned(meetingID:pinnedAt:)`. Remove the extra `.sorted { $0.startedAt > $1.startedAt }` from `MeetingLibraryViewModel.load()`.

**Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2.

Expected: all `MeetingRepositoryTests` and `MeetingLibraryViewModelTests` pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Persistence/Models/MeetingRecord.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "feat: persist pinned meeting ordering"
```

### Task 2: Add Notion page-title updates and the shared rename use case

**Files:**
- Create: `MeetingNotes/Domain/MeetingTitleUpdateUseCase.swift`
- Create: `MeetingNotesTests/MeetingTitleUpdateUseCaseTests.swift`
- Modify: `MeetingNotes/Notion/NotionModels.swift`
- Modify: `MeetingNotes/Notion/NotionClient.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotesTests/NotionClientTests.swift`

**Step 1: Write failing Notion request tests**

Add a test that calls `NotionClient.updatePageTitle(pageID:title:)` and asserts:

- method is `PATCH`;
- URL is `/v1/pages/<page-id>`;
- `Authorization` and `Notion-Version` headers remain present;
- JSON contains the page `title` property and trimmed text;
- more than 1,900 characters are safely truncated.

```swift
try await client.updatePageTitle(
    pageID: "39c48749-eaf5-80b8-a7a7-d2e9e1d27b3e",
    title: "季度复盘"
)
XCTAssertEqual(request.httpMethod, "PATCH")
XCTAssertEqual(request.url?.path, "/v1/pages/39c48749-eaf5-80b8-a7a7-d2e9e1d27b3e")
```

**Step 2: Run the Notion tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/NotionClientTests
```

Expected: compile failure because `updatePageTitle` is missing.

**Step 3: Implement the minimal Notion API method**

Extend `NotionAPIClient`:

```swift
func updatePageTitle(pageID: String, title: String) async throws
```

Add a `PATCH pages/{pageID}` request using the same title rich-text shape as page creation. Reject blank page IDs/titles and map errors through the existing `perform` method.

**Step 4: Run Notion tests and verify GREEN**

Run the command from Step 2.

Expected: all `NotionClientTests` pass.

**Step 5: Write failing use-case tests**

Define test doubles for a title repository, credential store, and remote Notion title updater. Cover:

1. blank titles are rejected without writes;
2. an unarchived meeting updates only SwiftData;
3. an archived meeting calls Notion first, then saves locally;
4. Notion failure leaves the local title unchanged;
5. missing Notion token/page ID blocks an archived rename;
6. local save failure after remote success triggers one compensating remote call with the old title.

The test should assert call order explicitly:

```swift
XCTAssertEqual(events, [
    .remote(pageID: pageID, title: "新标题"),
    .local(meetingID: meetingID, title: "新标题")
])
```

**Step 6: Run use-case tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingTitleUpdateUseCaseTests
```

Expected: compile failure because `MeetingTitleUpdateUseCase` and its errors/protocols do not exist.

**Step 7: Implement the shared title-update boundary**

Create these public-to-module boundaries:

```swift
enum MeetingTitleUpdateError: Error, Equatable, Sendable {
    case emptyTitle
    case operationInProgress
    case missingNotionCredential
    case missingNotionPage
    case notionUpdateFailed
    case localUpdateFailed
}

@MainActor
protocol MeetingTitleUpdating: AnyObject {
    func updateTitle(meetingID: UUID, title: String) async throws
}
```

Use a small `MeetingNotionTitleUpdating` live adapter that constructs `NotionClient` from the saved token and shared HTTP client. Add `MeetingRepository.updateTitle(meetingID:title:)`. Track in-flight meeting IDs in the use case, trim input once, and implement the remote-first/compensating-write flow from the approved design.

**Step 8: Run use-case and repository tests and verify GREEN**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingTitleUpdateUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/NotionClientTests
```

Expected: all selected tests pass.

**Step 9: Commit**

```bash
git add MeetingNotes/Domain/MeetingTitleUpdateUseCase.swift \
  MeetingNotes/Notion/NotionModels.swift MeetingNotes/Notion/NotionClient.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/MeetingTitleUpdateUseCaseTests.swift \
  MeetingNotesTests/NotionClientTests.swift
git commit -m "feat: synchronize meeting titles with Notion"
```

### Task 3: Expose pin, rename, and safe-delete operations through ViewModels

**Files:**
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing ViewModel behavior tests**

Add tests for:

- `togglePinned(id:at:)` pins with the provided time and reloads ordered meetings;
- a second toggle clears `pinnedAt`;
- `renameMeeting(id:title:)` reports a per-meeting in-flight state and maps title-update errors;
- Detail ViewModel uses the same `MeetingTitleUpdating` spy;
- busy meeting states reject deletion before the file directory is touched.

Define busy states as `.preparing`, `.recording`, `.paused`, `.finalizing`, `.summarizing`, and `.archiving`. Pin is always allowed; rename is disabled only during `.summarizing` and `.archiving`.

**Step 2: Run ViewModel tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: compile failures for the new actions/state.

**Step 3: Implement ViewModel operations**

Add state and methods to `MeetingLibraryViewModel`:

```swift
private(set) var pinningMeetingIDs: Set<UUID> = []
private(set) var renamingMeetingIDs: Set<UUID> = []

func togglePinned(id: UUID, at date: Date = .now)
func renameMeeting(id: UUID, title: String) async -> Bool
func canDelete(_ meeting: MeetingRecord) -> Bool
func canRename(_ meeting: MeetingRecord) -> Bool
```

Inject `MeetingTitleUpdating` into both ViewModels. Add `rename(to:) async -> Bool`, `isRenaming`, and rename-specific error mapping to `MeetingDetailViewModel`. Construct one `MeetingTitleUpdateUseCase` in `AppContainer` and inject it everywhere.

**Step 4: Run ViewModel tests and verify GREEN**

Run the command from Step 2.

Expected: all selected tests pass.

**Step 5: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: add meeting management view model actions"
```

### Task 4: Build native sidebar gestures and rename UI

**Files:**
- Create: `MeetingNotes/Views/MeetingRenameSheet.swift`
- Modify: `MeetingNotes/Views/MeetingSidebarView.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/RootView.swift`
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift`
- Modify: `MeetingNotes/App/LaunchArguments.swift` if UI fixtures need deterministic meetings

**Step 1: Write failing UI assertions for visible management affordances**

Add UI-test coverage for the reliable keyboard/mouse paths:

- right-click a history row and assert `重命名`, `置顶会议`, and `删除会议` exist;
- invoke rename, enter a title, save, and assert both sidebar and detail title update;
- invoke pin and assert the pinned accessibility value/icon;
- enter detail and use the title edit button to rename again.

Trackpad swipe itself remains a manual acceptance item because XCUITest does not reliably synthesize macOS two-finger list swipes.

**Step 2: Run the focused UI test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testMeetingManagementMenusAndRename
```

Expected: UI test fails because the menu items/edit button/accessibility identifiers do not exist.

**Step 3: Implement the reusable rename sheet**

Create a small SwiftUI sheet with a focused `TextField`, Cancel/Save buttons, Enter submission, blank validation, and these identifiers:

```swift
meeting.rename.field
meeting.rename.cancel
meeting.rename.save
```

Do not put Notion logic in the view; the save closure only calls the ViewModel.

**Step 4: Implement sidebar gestures and confirmation**

For each row add:

```swift
.swipeActions(edge: .leading, allowsFullSwipe: false) {
    Button(meeting.isPinned ? "取消置顶" : "置顶") { ... }
        .tint(.blue)
}
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    Button("删除", role: .destructive) { pendingDeletion = meeting }
}
.contextMenu { /* rename, pin/unpin, Divider, delete */ }
```

Use one confirmation dialog for swipe and context-menu deletion. Show a pin symbol and include pinned state in the row accessibility label/value.

**Step 5: Implement detail title edit mode**

Replace the static title with a view-local edit state:

- pencil button enters editing and focuses the field;
- Enter awaits `viewModel.rename(to:)` and exits only on success;
- Esc restores the original title;
- a progress indicator replaces/disables the pencil while saving;
- `onMeetingChanged` asks the library ViewModel to reload after success.

**Step 6: Run unit and UI tests and verify GREEN**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests

xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testMeetingManagementMenusAndRename
```

Expected: selected unit tests and the new UI flow pass.

**Step 7: Commit**

```bash
git add MeetingNotes/Views/MeetingRenameSheet.swift \
  MeetingNotes/Views/MeetingSidebarView.swift MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/Views/RootView.swift MeetingNotes/App/LaunchArguments.swift \
  MeetingNotesUITests/MeetingFlowUITests.swift
git commit -m "feat: add native meeting management interactions"
```

### Task 5: Make Whisper bilingual and sanitize all transcript text

**Files:**
- Create: `MeetingNotes/Transcription/TranscriptTextSanitizer.swift`
- Create: `MeetingNotesTests/TranscriptTextSanitizerTests.swift`
- Modify: `MeetingNotes/Transcription/WhisperKitTranscriptionService.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotesTests/TranscriptionQueueTests.swift` or add focused service-policy tests

**Step 1: Write sanitizer and decoding-policy tests**

Cover real strings from the local database:

```swift
XCTAssertEqual(
    TranscriptTextSanitizer.clean(
        "<|startoftranscript|><|zh|><|transcribe|><|7.00|> 我们开始开会。<|15.00|><|endoftext|>"
    ),
    "我们开始开会。"
)
XCTAssertEqual(
    TranscriptTextSanitizer.clean("<|en|> Let me test it."),
    "Let me test it."
)
XCTAssertNil(TranscriptTextSanitizer.nonEmpty("<|endoftext|>"))
```

Expose an internal `WhisperDecodingPolicy.options` value and assert `task == .transcribe`, `language == nil`, `detectLanguage == true`, and `skipSpecialTokens == true`.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/TranscriptTextSanitizerTests
```

Expected: compile failure because the sanitizer and policy do not exist.

**Step 3: Implement the pure sanitizer**

Use a deterministic scanner/regular expression for `<|...|>` tokens, then normalize whitespace without removing normal Chinese/English punctuation. Provide:

```swift
enum TranscriptTextSanitizer {
    static func clean(_ text: String) -> String
    static func nonEmpty(_ text: String) -> String?
}
```

**Step 4: Pass explicit WhisperKit decoding options**

Call:

```swift
let results = try await whisperKit.transcribe(
    audioArray: samples,
    decodeOptions: WhisperDecodingPolicy.options
)
```

Run both `result.text` and every `segment.text` through `nonEmpty` before creating drafts. Keep `.transcribe`; do not set a fixed language.

**Step 5: Defensively clean historical rows at display time**

In `TranscriptView`, render `TranscriptTextSanitizer.clean(transcript.text)` and omit rows that contain only control tokens. Do not rewrite historical SwiftData records during view rendering.

**Step 6: Run transcript tests and verify GREEN**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/TranscriptTextSanitizerTests \
  -only-testing:MeetingNotesTests/TranscriptionQueueTests
```

Expected: all selected tests pass and the production target compiles against the actual WhisperKit 1.0.0 method signature.

**Step 7: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptTextSanitizer.swift \
  MeetingNotes/Transcription/WhisperKitTranscriptionService.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotesTests/TranscriptTextSanitizerTests.swift \
  MeetingNotesTests/TranscriptionQueueTests.swift
git commit -m "fix: preserve spoken language in clean transcripts"
```

### Task 6: Make screen-recording permission retryable

**Files:**
- Modify: `MeetingNotes/Permissions/CapturePermissionClient.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/Views/RootView.swift`
- Modify: `MeetingNotesTests/CapturePermissionClientTests.swift`
- Modify: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`

**Step 1: Write failing permission tests**

Inject sendable closures into `LiveCapturePermissionSystem` for screen preflight/request so the live decision logic is testable without changing TCC. Assert:

- preflight false reports `.notDetermined` every time, even after a failed request;
- each online retry calls the screen request again;
- offline requests only microphone;
- the Library ViewModel retains the last failed mode and retry calls start again once.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/CapturePermissionClientTests \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: the repeated-request test fails because UserDefaults converts all later states to `.denied`; retry-mode APIs are missing.

**Step 3: Remove the sticky UserDefaults gate**

Replace the screen status branch with:

```swift
return screenPreflight() ? .authorized : .notDetermined
```

The request closure returns `.authorized` or `.denied` from `CGRequestScreenCaptureAccess()`. Do not persist a “requested” flag.

**Step 4: Add a visible retry path**

Store `lastFailedStartMode` when a permission denial occurs. Add `retryLastStart()` that clears stale UI state and invokes `startMeeting(mode:)`. In `RootView`, show `重新检测` beside the existing settings link whenever permission repair items exist. Update the screen-recording error text to mention that macOS may require fully quitting and reopening the App.

**Step 5: Run focused tests and verify GREEN**

Run the command from Step 2.

Expected: all selected tests pass.

**Step 6: Commit**

```bash
git add MeetingNotes/Permissions/CapturePermissionClient.swift \
  MeetingNotes/ViewModels/MeetingLibraryViewModel.swift MeetingNotes/Views/RootView.swift \
  MeetingNotesTests/CapturePermissionClientTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "fix: allow screen recording permission retries"
```

### Task 7: Reset the coordinator after a successful meeting

**Files:**
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write the failing sequential-session tests**

Add tests that start, stop, and start again on the same coordinator fixture. Cover offline→offline and offline→online; assert the repository has two distinct meeting IDs and the second capture mode is correct.

```swift
try await fixture.coordinator.start(mode: .offline)
let firstID = await fixture.coordinator.snapshot().meetingID
try await fixture.coordinator.stop()
XCTAssertEqual(await fixture.coordinator.snapshot().state, .idle)

try await fixture.coordinator.start(mode: .online)
let secondID = await fixture.coordinator.snapshot().meetingID
XCTAssertNotEqual(firstID, secondID)
```

Update the old stop assertion from `.ready` to the new reusable idle snapshot, while still asserting the persisted meeting state is `.ready`.

**Step 2: Run coordinator tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: second start throws `RecordingStateMachineError.invalidTransition(.ready, .prepare)`.

**Step 3: Implement successful-session reset**

After repository finalize and state-machine `.finalized` succeed, call a dedicated reset that:

```swift
stateMachine = RecordingStateMachine()
meetingID = nil
mode = nil
releaseActiveResources()
bookmarkCount = 0
finalActiveDuration = 0
captureFailed = false
```

Do not use this successful reset in the catch path. Preserve the stop-before-reset meeting ID in `MeetingControlRouter`, which already captures the snapshot before calling stop.

**Step 4: Run coordinator tests and verify GREEN**

Run the command from Step 2.

Expected: all coordinator tests pass, including sequential sessions and the existing finalize ordering assertions.

**Step 5: Commit**

```bash
git add MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "fix: reset coordinator between meetings"
```

### Task 8: Validate segmented recordings and build a continuous audio source

**Files:**
- Create: `MeetingNotes/Playback/MeetingAudioSourceLoader.swift`
- Create: `MeetingNotesTests/MeetingAudioSourceLoaderTests.swift`
- Modify: `MeetingNotes/Recording/MeetingFileStore.swift`

**Step 1: Write failing source-loader tests**

Use `SegmentedPCMWriter` with a tiny frame limit to create three real CAF files. Assert the loader returns ordered URLs, exact total frames, 16 kHz sample rate, and exact duration. Add failure tests for a missing manifest, an incomplete segment, a missing file, and an unreadable/corrupt CAF.

```swift
let source = try await loader.load(meetingID: meetingID)
XCTAssertEqual(source.segmentURLs.map(\.lastPathComponent), [
    "segment-0001.caf", "segment-0002.caf", "segment-0003.caf"
])
XCTAssertEqual(source.duration, Double(source.totalFrames) / 16_000, accuracy: 0.0001)
```

**Step 2: Run source-loader tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingAudioSourceLoaderTests
```

Expected: compile failure because the loader/source/error types do not exist.

**Step 3: Implement a sendable validated source description**

Create:

```swift
struct MeetingAudioSource: Equatable, Sendable {
    let meetingID: UUID
    let segmentURLs: [URL]
    let segmentFrameCounts: [Int64]
    let sampleRate: Double
    let totalFrames: Int64
    let manifestSignature: String
    var duration: TimeInterval { Double(totalFrames) / sampleRate }
}
```

The actor loader reads the manifest through `MeetingFileStore`, requires at least one complete segment, resolves every URL under the recordings root, opens each with `AVAudioFile`, and verifies sample rate/channel count/frame length. Build a stable manifest signature from version, sample rate, channel count, filenames, frame counts, and completion flags.

**Step 4: Run source-loader tests and verify GREEN**

Run the command from Step 2.

Expected: all loader tests pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Playback/MeetingAudioSourceLoader.swift \
  MeetingNotes/Recording/MeetingFileStore.swift \
  MeetingNotesTests/MeetingAudioSourceLoaderTests.swift
git commit -m "feat: load continuous meeting audio sources"
```

### Task 9: Generate and cache real waveform samples

**Files:**
- Create: `MeetingNotes/Playback/WaveformAnalyzer.swift`
- Create: `MeetingNotesTests/WaveformAnalyzerTests.swift`
- Modify: `MeetingNotes/Recording/MeetingFileStore.swift`

**Step 1: Write failing waveform tests**

Create deterministic CAF segments containing silence, a low sine wave, and a high sine wave. Assert:

- exactly the requested bucket count is returned;
- all values are finite and clamped to `0...1`;
- high-amplitude buckets exceed low-amplitude buckets;
- silent buckets retain only the view’s minimum visual height, not fabricated audio energy;
- a matching cache avoids opening audio again;
- changing the manifest signature invalidates the cache.

**Step 2: Run waveform tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/WaveformAnalyzerTests
```

Expected: compile failure because waveform snapshot/analyzer/cache APIs do not exist.

**Step 3: Add atomic waveform cache I/O**

Add `waveform-v1.json` methods to `MeetingFileStore` using the same temporary-write-and-replace strategy as the manifest. Cache:

```swift
struct WaveformSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let manifestSignature: String
    let values: [Float]
}
```

**Step 4: Implement background RMS aggregation**

Read each CAF in bounded buffers. Map the global frame index into `bucketCount` accumulators, store sum-of-squares and counts, compute RMS, normalize to the largest meaningful RMS, apply a square-root display curve, and clamp to `0...1`. Do not load the complete meeting into memory.

**Step 5: Run waveform tests and verify GREEN**

Run the command from Step 2.

Expected: all waveform tests pass.

**Step 6: Commit**

```bash
git add MeetingNotes/Playback/WaveformAnalyzer.swift \
  MeetingNotes/Recording/MeetingFileStore.swift \
  MeetingNotesTests/WaveformAnalyzerTests.swift
git commit -m "feat: analyze and cache meeting waveforms"
```

### Task 10: Implement one shared AVPlayer controller

**Files:**
- Create: `MeetingNotes/Playback/MeetingAudioPlayerController.swift`
- Create: `MeetingNotesTests/MeetingAudioPlayerControllerTests.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`

**Step 1: Write failing controller-state tests**

Use an injected playback-engine spy instead of waiting on real wall-clock playback. Cover:

- prepare transitions `idle → loading → ready` with duration/waveform;
- play and pause preserve current time;
- seek clamps to `0...duration`;
- dragging stores preview time and restores the pre-drag play/pause intention;
- end notification sets `.ended` and displays total duration;
- preparing another meeting stops the previous one;
- `stop(meetingID:)` ignores unrelated meetings and releases observers for the matching one;
- waveform failure leaves audio ready with an empty/fallback waveform.

**Step 2: Run controller tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingAudioPlayerControllerTests
```

Expected: compile failure because controller, state, and playback engine boundaries do not exist.

**Step 3: Implement the AVFoundation engine adapter**

Define a small testable engine protocol on `@MainActor`. The live engine asynchronously creates an `AVMutableComposition`, loads the first audio track from every source URL, inserts each full segment at the running cursor, and builds one `AVPlayerItem`. Install a periodic time observer at approximately 30 Hz and an end notification observer; remove both on replacement/deinit.

**Step 4: Implement the observable controller**

Create:

```swift
enum MeetingAudioPlayerState: Equatable {
    case idle, loading, ready, playing, paused, ended
    case failed(String)
}

@MainActor @Observable
final class MeetingAudioPlayerController {
    private(set) var meetingID: UUID?
    private(set) var state: MeetingAudioPlayerState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var waveform: [Float] = []

    func prepare(meetingID: UUID) async
    func togglePlayback()
    func beginSeeking(to fraction: Double)
    func updateSeeking(to fraction: Double)
    func endSeeking(at fraction: Double)
    func stop(meetingID: UUID? = nil)
}
```

Use generation IDs/cancellation so a late result from an old selection cannot overwrite the current meeting state.

**Step 5: Stop playback before deletion**

Inject a narrow `MeetingPlaybackStopping` protocol into `MeetingLibraryViewModel`. In `deleteMeeting`, call it before deleting the directory. Wire the one shared controller in `AppContainer`.

**Step 6: Run controller and library tests and verify GREEN**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingAudioPlayerControllerTests \
  -only-testing:MeetingNotesTests/MeetingLibraryViewModelTests
```

Expected: all selected tests pass.

**Step 7: Commit**

```bash
git add MeetingNotes/Playback/MeetingAudioPlayerController.swift \
  MeetingNotes/App/AppContainer.swift MeetingNotes/ViewModels/MeetingLibraryViewModel.swift \
  MeetingNotesTests/MeetingAudioPlayerControllerTests.swift \
  MeetingNotesTests/MeetingLibraryViewModelTests.swift
git commit -m "feat: add shared meeting audio playback controller"
```

### Task 11: Draw the draggable vertical-bar waveform player

**Files:**
- Create: `MeetingNotes/Views/WaveformProgressView.swift`
- Create: `MeetingNotes/Views/MeetingAudioPlayerView.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotes/App/MeetingNotesApp.swift` or root composition if environment injection is needed
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift`

**Step 1: Write a failing UI test for player affordances**

Seed a UI-test meeting with deterministic audio segments. Open its detail and assert:

- play/pause button exists;
- current and total time exist;
- waveform has an adjustable accessibility value;
- pressing play changes the button to pause;
- an accessibility increment/seek changes the displayed current time.

Use identifiers:

```text
meeting.audioPlayer
meeting.audioPlayer.toggle
meeting.audioPlayer.waveform
meeting.audioPlayer.currentTime
meeting.audioPlayer.duration
```

**Step 2: Run the player UI test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testLocalRecordingPlayer
```

Expected: failure because the player identifiers are absent.

**Step 3: Implement an efficient Canvas waveform**

Use `Canvas` inside `GeometryReader` rather than one SwiftUI view per bar. Determine the visible bar count from width and a 2-point bar/2-point gap rhythm, resample waveform values to that count, and draw rounded vertical rectangles. Split each bar color by whether its center fraction is below `progress`.

Attach `DragGesture(minimumDistance: 0)`:

```swift
let fraction = min(max(value.location.x / max(width, 1), 0), 1)
onSeekChanged(fraction)
// End calls onSeekEnded(fraction).
```

Expose `.accessibilityAdjustableAction` in five-second increments and a readable percentage/time value.

**Step 4: Implement the minimal player chrome**

Place the large play/pause button, waveform, current time, and total time in the existing adaptive glass audio card. Show a small progress indicator while loading, a fallback draggable flat bar if waveform generation fails, and an error message only if audio itself cannot load.

Call `prepare(meetingID:)` when the finished meeting detail appears. Stop the matching meeting on disappear; re-prepare if the selected meeting changes.

**Step 5: Preserve macOS 26 Liquid Glass compatibility**

Reuse `AdaptiveGlassCard`, `adaptivePrimaryButtonStyle`, and existing motion policy. Do not introduce custom blur/material branches outside the established macOS 26 native-glass/macOS 15–25 material fallback.

**Step 6: Run unit, UI, and accessibility-focused tests**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingAudioSourceLoaderTests \
  -only-testing:MeetingNotesTests/WaveformAnalyzerTests \
  -only-testing:MeetingNotesTests/MeetingAudioPlayerControllerTests

xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests/testLocalRecordingPlayer
```

Expected: all selected tests pass.

**Step 7: Commit**

```bash
git add MeetingNotes/Views/WaveformProgressView.swift \
  MeetingNotes/Views/MeetingAudioPlayerView.swift MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/App/AppContainer.swift MeetingNotesUITests/MeetingFlowUITests.swift \
  MeetingNotes/App/LaunchArguments.swift
git commit -m "feat: add draggable waveform recording player"
```

### Task 12: Full regression, migration, and real-build acceptance

**Files:**
- Modify: `README.md`
- Modify: `docs/testing/manual-apple-silicon-checklist.md`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift` if the persistent-store migration fixture reveals an issue
- Modify: `MeetingNotesUITests/MeetingFlowUITests.swift` for any missing regression assertion

**Step 1: Verify the existing real store opens with `pinnedAt == nil`**

Back up before any destructive test:

```bash
cp "$HOME/Library/Containers/com.shenminghao.MeetingNotes/Data/Library/Application Support/default.store" \
  "/tmp/MeetingNotes-default-store-before-pin-$(date +%Y%m%d-%H%M%S).store"
```

Build and launch only after unit migration tests pass. Confirm existing meetings remain visible and unpinned. Never delete or rewrite the backup.

**Step 2: Run the complete arm64 unit suite**

Run:

```bash
xcodebuild clean test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-feature-unit-build \
  CODE_SIGNING_ALLOWED=NO -only-testing:MeetingNotesTests
```

Expected: every unit test passes with zero Swift 6 concurrency errors.

**Step 3: Run the complete signed UI suite**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-feature-ui-build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesUITests/MeetingFlowUITests \
  -only-testing:MeetingNotesTests/LongRecordingHarnessTests
```

Expected: all UI flows and long-recording harness tests pass.

**Step 4: Build the one fixed real-acceptance app**

Run:

```bash
xcodebuild clean build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/meetingnotes-feature-real-build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

file /tmp/meetingnotes-feature-real-build/Build/Products/Debug/MeetingNotes.app/Contents/MacOS/MeetingNotes
lipo -archs /tmp/meetingnotes-feature-real-build/Build/Products/Debug/MeetingNotes.app/Contents/MacOS/MeetingNotes
codesign --verify --deep --strict --verbose=2 \
  /tmp/meetingnotes-feature-real-build/Build/Products/Debug/MeetingNotes.app
```

Expected: Mach-O arm64 only and strict code-sign verification succeeds. Do not rebuild this binary after granting TCC permissions.

**Step 5: Perform manual interaction acceptance with the user**

Open the fixed app and verify, in order:

1. existing history loads and existing control-code text displays cleanly;
2. right-click rename/pin/delete and physical trackpad leading/trailing swipes work;
3. record a Chinese offline meeting, stop it, play and drag the real waveform;
4. immediately start a second offline meeting and stop it;
5. record an English or mixed-language clip and inspect language retention;
6. remove/re-add Screen & System Audio Recording permission for this exact final build if needed, fully quit/reopen, then record an online meeting;
7. archive a meeting, rename it, and verify the Notion page title changes;
8. simulate a missing token/network failure and confirm the local archived title does not diverge.

**Step 6: Update documentation with exact evidence**

Record test totals, build path, architecture/signature output, known signing limitation, and the user-confirmed manual results. Do not claim real online capture or Notion synchronization passed until the user performs those actions.

**Step 7: Run final diff and repository checks**

Run:

```bash
git diff --check
git status --short
git log --oneline -12
```

Expected: no whitespace errors; only intended documentation/test changes remain before the final commit.

**Step 8: Commit acceptance documentation**

```bash
git add README.md docs/testing/manual-apple-silicon-checklist.md \
  MeetingNotesTests MeetingNotesUITests
git commit -m "test: document meeting management and playback acceptance"
```

### Task 13: Required review and completion gate

**Files:**
- Review all files changed since design commit `d5420c7`

**Step 1: Invoke the code-review skill**

Use `@requesting-code-review` (or the available `code-reviewer` skill) to inspect the implementation against:

- `docs/plans/2026-07-15-meeting-library-transcription-playback-design.md`;
- this implementation plan;
- Swift 6 actor isolation and Sendable correctness;
- data migration and Notion compensation behavior;
- AVPlayer observer cleanup and file-deletion safety;
- permission behavior for offline versus online meetings.

**Step 2: Address actionable review findings with RED/GREEN tests**

For every confirmed bug, first add a failing regression test, run it, make the minimal fix, and rerun the relevant focused suite. Commit review fixes separately:

```bash
git add <reviewed-files>
git commit -m "fix: address meeting reliability review"
```

**Step 3: Invoke verification-before-completion**

Rerun the complete unit suite, signed UI suite, clean arm64 build, `codesign --verify`, `git diff --check`, and inspect the final status. Only then report implementation complete or offer branch integration options through `@finishing-a-development-branch`.
