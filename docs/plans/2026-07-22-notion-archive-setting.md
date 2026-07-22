# Optional Notion Archiving Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a default-on setting that lets users keep generated meeting summaries only in MeetingNotes without calling Notion, while allowing later archival of the existing local summary.

**Architecture:** Store the preference in the shared observable `AppSettingsStore`, expose it through `SettingsViewModel`, and branch in `SummarizeAndArchiveUseCase` only after the local summary is safely persisted. Inject the same settings store into `MeetingDetailViewModel` so button labels and enabled states update when the saved preference changes.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation `UserDefaults`, XCTest, Xcode/xcodebuild.

---

### Task 1: Persist and edit the Notion archive preference

**Files:**
- Modify: `MeetingNotesTests/AppSettingsStoreTests.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`
- Modify: `MeetingNotes/Settings/AppSettingsStore.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`

**Step 1: Write the failing store tests**

Extend `AppSettingsStoreTests` with assertions that a new store defaults to enabled and that `false` survives reconstruction:

```swift
func testNotionArchivingDefaultsToEnabledAndPersistsDisabledChoice() throws {
    let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = AppSettingsStore(defaults: defaults)
    XCTAssertTrue(first.isNotionArchivingEnabled)

    first.isNotionArchivingEnabled = false

    let reloaded = AppSettingsStore(defaults: defaults)
    XCTAssertFalse(reloaded.isNotionArchivingEnabled)
}
```

**Step 2: Write the failing settings view-model test**

Extend `testSaveWritesSecretsToCredentialStoreAndNonSecretsToSettings` or add a focused test:

```swift
func testLoadAndSaveRoundTripsNotionArchivePreference() throws {
    let fixture = try makeFixture()
    XCTAssertTrue(fixture.settings.isNotionArchivingEnabled)

    fixture.viewModel.load()
    XCTAssertTrue(fixture.viewModel.isNotionArchivingEnabled)

    fixture.viewModel.isNotionArchivingEnabled = false
    fixture.viewModel.save()

    XCTAssertFalse(fixture.settings.isNotionArchivingEnabled)
}
```

**Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/AppSettingsStoreTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests
```

Expected: compilation fails because `isNotionArchivingEnabled` does not exist.

**Step 4: Implement the observable persisted setting**

In `AppSettingsStore.swift`, import Observation, mark the class `@Observable`, add the key, and initialize a stored property that persists changes:

```swift
import Foundation
import Observation

@Observable
final class AppSettingsStore: @unchecked Sendable {
    static let defaultDeepSeekModel = "deepseek-v4-flash"

    private enum Key {
        static let deepSeekModel = "settings.deepSeekModel"
        static let notionParentPageURL = "settings.notionParentPageURL"
        static let notionArchivingEnabled = "settings.notionArchivingEnabled"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var isNotionArchivingEnabled: Bool {
        didSet {
            defaults.set(
                isNotionArchivingEnabled,
                forKey: Key.notionArchivingEnabled
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.notionArchivingEnabled) == nil {
            isNotionArchivingEnabled = true
        } else {
            isNotionArchivingEnabled = defaults.bool(
                forKey: Key.notionArchivingEnabled
            )
        }
    }
```

Keep the existing model and Notion URL properties unchanged.

**Step 5: Implement settings view-model load and save**

Add the editable property:

```swift
var isNotionArchivingEnabled = true
```

In `load()`:

```swift
isNotionArchivingEnabled = settingsStore.isNotionArchivingEnabled
```

In `save()` before reporting success:

```swift
settingsStore.isNotionArchivingEnabled = isNotionArchivingEnabled
```

**Step 6: Add the settings UI**

At the top of the Notion card in `SettingsView.swift`, below the heading, add:

```swift
Toggle(
    "总结后自动归档到 Notion",
    isOn: $viewModel.isNotionArchivingEnabled
)
.accessibilityIdentifier("settings.notion.archiveEnabled")

Text(
    viewModel.isNotionArchivingEnabled
        ? "生成总结后会继续写入已配置的 Notion 父页面。"
        : "总结只保存在本软件中，不会连接 Notion。"
)
.font(.caption)
.foregroundStyle(.secondary)
```

Do not hide or clear the token, parent-page URL, or connection test controls.

**Step 7: Run the focused tests and verify GREEN**

Run the command from Step 3.

Expected: both test classes pass with zero failures.

**Step 8: Commit**

```bash
git add MeetingNotes/Settings/AppSettingsStore.swift \
  MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotes/Views/SettingsView.swift \
  MeetingNotesTests/AppSettingsStoreTests.swift \
  MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "feat: add Notion archive preference"
```

### Task 2: Stop after local summary when Notion archiving is disabled

**Files:**
- Modify: `MeetingNotesTests/SummarizeAndArchiveUseCaseTests.swift`
- Modify: `MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift`

**Step 1: Write the failing local-only behavior test**

Update the fixture to retain `settings` and accept `notionArchivingEnabled`. Add:

```swift
func testDisabledNotionArchivingSavesSummaryLocallyWithoutCallingNotion() async throws {
    let fixture = try makeFixture(notionArchivingEnabled: false)
    let meetingID = try fixture.makeReadyMeeting()
    try fixture.addFinalTranscript(to: meetingID)

    try await fixture.useCase.execute(meetingID: meetingID)

    let meeting = try fixture.repository.meeting(id: meetingID)
    XCTAssertEqual(meeting.state, .summaryReady)
    XCTAssertEqual(meeting.summary?.overview, "确认启动计划")
    XCTAssertNil(meeting.notionPageID)
    XCTAssertEqual(fixture.archiver.callCount, 0)
    XCTAssertEqual(await fixture.generator.callCount(), 1)
}
```

Configure the fixture without a Notion credential for this test so it proves the disabled path never validates Notion configuration.

**Step 2: Write the failing re-enable test**

```swift
func testReenablingNotionArchivesExistingSummaryWithoutRegenerating() async throws {
    let fixture = try makeFixture(notionArchivingEnabled: false)
    let meetingID = try fixture.makeReadyMeeting()
    try fixture.addFinalTranscript(to: meetingID)

    try await fixture.useCase.execute(meetingID: meetingID)
    fixture.settings.isNotionArchivingEnabled = true
    try fixture.credentials.save("notion-token", for: .notionToken)
    try await fixture.useCase.execute(meetingID: meetingID)

    XCTAssertEqual(await fixture.generator.callCount(), 1)
    XCTAssertEqual(fixture.archiver.callCount, 1)
    XCTAssertEqual(
        try fixture.repository.meeting(id: meetingID).state,
        .archived
    )
}
```

**Step 3: Run the focused use-case tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/SummarizeAndArchiveUseCaseTests
```

Expected: the local-only test fails because the existing use case attempts Notion archival.

**Step 4: Add the minimal workflow branch**

In `execute(meetingID:onProgress:)`, preserve local summary generation and state transitions, then guard before both calls to `archiveExistingSummary`:

```swift
case .summaryReady:
    onProgress(.summaryReady)
    guard settingsStore.isNotionArchivingEnabled else { return }
    try await archiveExistingSummary(
        meetingID: meetingID,
        onProgress: onProgress
    )
case .ready:
    if meeting.summary == nil {
        try await generateSummary(
            meetingID: meetingID,
            onProgress: onProgress
        )
    } else {
        try repository.updateMeetingState(
            id: meetingID,
            state: .summaryReady
        )
        onProgress(.summaryReady)
    }
    guard settingsStore.isNotionArchivingEnabled else { return }
    try await archiveExistingSummary(
        meetingID: meetingID,
        onProgress: onProgress
    )
```

Do not move the guard before `generateSummary`; the local summary must still be generated and saved.

**Step 5: Run the focused use-case tests and verify GREEN**

Run the command from Step 3.

Expected: all `SummarizeAndArchiveUseCaseTests` pass with zero failures.

**Step 6: Commit**

```bash
git add MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift \
  MeetingNotesTests/SummarizeAndArchiveUseCaseTests.swift
git commit -m "feat: support local-only summaries"
```

### Task 3: Make meeting-detail actions reflect the saved preference

**Files:**
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`

**Step 1: Write failing primary-action tests**

Add cases that construct a dedicated `AppSettingsStore` and inject it into the view model:

```swift
func testPrimaryActionUsesNotionArchivePreference() throws {
    let repository = try MeetingRepository.inMemory()
    let meetingID = try repository.createMeeting(
        mode: .offline,
        startedAt: .now
    )
    try repository.updateMeetingState(id: meetingID, state: .ready)
    let settings = makeSettings()
    settings.isNotionArchivingEnabled = false
    let viewModel = MeetingDetailViewModel(
        meetingID: meetingID,
        repository: repository,
        action: DetailActionSpy(),
        titleUpdater: DetailTitleUpdaterSpy(),
        settingsStore: settings
    )

    XCTAssertEqual(viewModel.primaryAction, .summarizeLocally)

    try repository.updateMeetingState(id: meetingID, state: .summaryReady)
    viewModel.load()
    XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)

    settings.isNotionArchivingEnabled = true
    XCTAssertEqual(viewModel.primaryAction, .archiveToNotion)
}
```

Add a test helper that creates an isolated `UserDefaults` suite and registers cleanup. Update all existing view-model constructions in this test file to pass a test settings store.

**Step 2: Run the detail view-model tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: compilation fails because the new action cases and initializer dependency do not exist.

**Step 3: Add preference-aware action cases**

Replace the retry-specific action with explicit destination states:

```swift
enum MeetingDetailPrimaryAction: Equatable, Sendable {
    case unavailable
    case summarizeAndArchive
    case summarizeLocally
    case summarizing
    case archiveToNotion
    case localSummarySaved
    case archiving
    case archived
}
```

Use these titles:

```swift
case .summarizeAndArchive: "总结并归档"
case .summarizeLocally: "生成总结"
case .archiveToNotion: "归档到 Notion"
case .localSummarySaved: "已保存到本机"
```

Enable only `.summarizeAndArchive`, `.summarizeLocally`, and `.archiveToNotion`. Use `sparkles` for both summary actions, `square.and.arrow.up` for Notion archival, and `checkmark.circle.fill` for the saved/archived states.

**Step 4: Inject the shared settings store**

Add `settingsStore` to `MeetingDetailViewModel` and expose a read-only computed property:

```swift
private let settingsStore: AppSettingsStore

var isNotionArchivingEnabled: Bool {
    settingsStore.isNotionArchivingEnabled
}
```

Map states as follows:

```swift
case .ready:
    isNotionArchivingEnabled ? .summarizeAndArchive : .summarizeLocally
case .summaryReady:
    isNotionArchivingEnabled ? .archiveToNotion : .localSummarySaved
```

During an in-progress operation, map `.summaryReady` to `.archiving` only when Notion is enabled; otherwise map it to `.localSummarySaved`.

In `AppContainer`, retain the shared store:

```swift
private let settingsStore: AppSettingsStore
```

Assign it after resolving the optional initializer argument, then pass it to every `MeetingDetailViewModel` created by `detailViewModel(for:)`.

**Step 5: Update meeting-detail copy**

In `MeetingDetailView.swift`:

- When no summary exists, say either “可生成总结并归档到 Notion” or “可生成总结并保存在本软件中” based on the setting.
- When a local summary exists without a Notion URL and the setting is disabled, show “已保存在本机”.
- Otherwise show “尚未归档到 Notion”.
- Change `MeetingDisplayFormat.state(.summaryReady)` from “待归档” to “总结完成”.

Keep the existing accessibility identifier `meeting.summarizeArchive` so UI automation remains stable.

**Step 6: Run the detail view-model tests and verify GREEN**

Run the command from Step 2.

Expected: all `MeetingDetailViewModelTests` pass with zero failures.

**Step 7: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: reflect archive preference in meeting details"
```

### Task 4: Update privacy copy and verify the complete feature

**Files:**
- Modify: `MeetingNotes/Views/OnboardingView.swift`
- Modify: `README.md`

**Step 1: Update user-facing privacy text**

In `OnboardingView.swift`, replace the wording tied to the old button label:

```swift
title: "只有点击生成总结时才会联网",
detail: "转录文本会发送给 DeepSeek；是否继续写入 Notion 由你的设置决定。"
```

Update the README privacy, usage, and Notion settings sections to document:

- DeepSeek is contacted when the user generates a summary.
- Notion is contacted only when the default-on archive setting is enabled.
- With the setting disabled, summaries remain local.
- Re-enabling allows archival of an existing summary without regenerating it.

**Step 2: Run all affected tests**

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests/AppSettingsStoreTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  -only-testing:MeetingNotesTests/SummarizeAndArchiveUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: zero failures.

**Step 3: Run the complete unit-test suite**

```bash
xcodebuild clean test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO \
  -only-testing:MeetingNotesTests
```

Expected: all unit tests pass with zero failures.

**Step 4: Run a Release build**

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

**Step 5: Inspect the final diff**

```bash
git status -sb
git diff --check
git diff --stat HEAD~3..HEAD
```

Expected: no whitespace errors and only the approved settings, workflow, UI, tests, and documentation files are changed.

**Step 6: Commit documentation changes**

```bash
git add MeetingNotes/Views/OnboardingView.swift README.md
git commit -m "docs: explain optional Notion archiving"
```
