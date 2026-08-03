# Frequent Speaker Name Synchronization Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make frequent speaker names persist immediately and merge safely across Settings and transcript rename flows without stale Settings state overwriting shared data.

**Architecture:** Keep `AppSettingsStore.frequentSpeakerNames` as the single persisted source of truth. `SettingsViewModel` may retain a presentation copy, but every add/remove operation must derive from and immediately write the latest store value, while the general `save()` operation must never write the potentially stale presentation copy back.

**Tech Stack:** Swift 6, SwiftUI Observation, UserDefaults-backed `AppSettingsStore`, XCTest, Xcode 17.

---

### Task 1: Reproduce immediate-persistence and stale-overwrite failures

**Files:**
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift:1098-1124`
- Test: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: Write the failing add-and-merge test**

Add a test that loads an initial name, simulates a transcript rename adding another name directly to the shared store, then adds a third name from Settings:

```swift
func testAddFrequentSpeakerNamePersistsAndMergesLatestStore() throws {
    let fixture = try makeFixture()
    fixture.settings.frequentSpeakerNames = ["张三"]
    fixture.viewModel.load()
    fixture.settings.rememberSpeakerName("李四")

    fixture.viewModel.newSpeakerName = " 王老师 "
    fixture.viewModel.addFrequentSpeakerName()

    XCTAssertEqual(
        fixture.viewModel.frequentSpeakerNames,
        ["张三", "李四", "王老师"]
    )
    XCTAssertEqual(
        fixture.settings.frequentSpeakerNames,
        ["张三", "李四", "王老师"]
    )
    XCTAssertEqual(fixture.viewModel.newSpeakerName, "")
}
```

**Step 2: Write the failing save-does-not-overwrite test**

```swift
func testSavingOtherSettingsKeepsNameRememberedAfterLoad() async throws {
    let fixture = try makeFixture()
    fixture.settings.frequentSpeakerNames = ["张三"]
    fixture.viewModel.load()
    fixture.settings.rememberSpeakerName("李四")

    let saved = await fixture.viewModel.save()

    XCTAssertTrue(saved)
    XCTAssertEqual(
        fixture.settings.frequentSpeakerNames,
        ["张三", "李四"]
    )
    XCTAssertEqual(
        fixture.viewModel.frequentSpeakerNames,
        ["张三", "李四"]
    )
}
```

**Step 3: Update the removal test to require immediate persistence**

Replace the existing save-dependent removal test with:

```swift
func testRemoveFrequentSpeakerNamePersistsImmediately() throws {
    let fixture = try makeFixture()
    fixture.settings.frequentSpeakerNames = ["张三", "李四"]
    fixture.viewModel.load()

    fixture.viewModel.removeFrequentSpeakerName("张三")

    XCTAssertEqual(fixture.viewModel.frequentSpeakerNames, ["李四"])
    XCTAssertEqual(fixture.settings.frequentSpeakerNames, ["李四"])
}
```

**Step 4: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-frequent-speaker-sync-red \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the three new/updated tests fail because Settings additions/removals are not written immediately and `save()` overwrites the externally remembered name.

### Task 2: Make the shared store authoritative

**Files:**
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift:318-386`
- Test: `MeetingNotesTests/SettingsViewModelTests.swift`

**Step 1: Implement immediate add based on the latest store value**

Replace `addFrequentSpeakerName()` with:

```swift
func addFrequentSpeakerName() {
    settingsStore.frequentSpeakerNames =
        settingsStore.frequentSpeakerNames + [newSpeakerName]
    frequentSpeakerNames = settingsStore.frequentSpeakerNames
    newSpeakerName = ""
}
```

`AppSettingsStore` remains responsible for trimming, length validation, stable ordering, and case-insensitive deduplication.

**Step 2: Implement immediate removal based on the latest store value**

Replace `removeFrequentSpeakerName(_:)` with:

```swift
func removeFrequentSpeakerName(_ name: String) {
    settingsStore.frequentSpeakerNames.removeAll {
        $0.localizedCaseInsensitiveCompare(name) == .orderedSame
    }
    frequentSpeakerNames = settingsStore.frequentSpeakerNames
}
```

If direct mutation of the computed property is rejected by Swift, use a local `updatedNames` variable, remove from it, then assign it back once.

**Step 3: Prevent general Settings save from overwriting the shared list**

Delete:

```swift
settingsStore.frequentSpeakerNames = frequentSpeakerNames
```

After other settings are persisted, refresh the presentation copy:

```swift
frequentSpeakerNames = settingsStore.frequentSpeakerNames
```

**Step 4: Run the focused tests and verify GREEN**

Run the Task 1 command again.

Expected: all `SettingsViewModelTests` pass, including the three regression cases.

**Step 5: Run related speaker-name tests**

Run:

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-frequent-speaker-sync-green \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  -only-testing:MeetingNotesTests/AppSettingsStoreTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all selected tests pass with zero failures.

**Step 6: Commit the fix**

```bash
git add MeetingNotes/ViewModels/SettingsViewModel.swift MeetingNotesTests/SettingsViewModelTests.swift
git commit -m "fix: synchronize frequent speaker names"
```

### Task 3: Verify and refresh the local test application

**Files:**
- Verify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Verify: `MeetingNotesTests/SettingsViewModelTests.swift`
- Build artifact: `.deriveddata-frequent-speaker-sync-release/Build/Products/Release/MeetingNotes.app`

**Step 1: Run the complete unit test target**

```bash
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-frequent-speaker-sync-final \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  -only-testing:MeetingNotesTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all unit tests pass with zero failures.

**Step 2: Run the existing speaker Settings UI regression**

Run the existing `testPartialArchiveSpeakerRenameAndFrequentNameSettings` UI test from a signed DerivedData directory outside the protected Documents runtime path if required.

Expected: the Settings and transcript speaker-name workflow passes with zero failures.

**Step 3: Build and sign an arm64 Release app**

```bash
xcodebuild build \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-frequent-speaker-sync-release \
  -clonedSourcePackagesDirPath .deriveddata-live-speakers-task8-green/SourcePackages \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Re-sign using `Configuration/MeetingNotes.entitlements`, then verify deep signature, arm64 architecture, and absence of `get-task-allow`.

**Step 4: Replace only the local test copy**

Replace `/Users/shenminghao/Applications/MeetingNotes 测试版.app` with the verified Release build using a staged copy and reversible backup. Do not modify `/Applications/MeetingNotes.app`, build a DMG, or push GitHub.

**Step 5: Final repository checks**

Run `git diff --check`, confirm no tracked modifications remain, and leave pre-existing `.deriveddata-*` and `.sandbox-*` directories untracked.
