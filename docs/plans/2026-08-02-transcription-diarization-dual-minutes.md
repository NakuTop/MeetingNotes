# Transcription Quality, Reliable Diarization, and Dual Minutes Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add selectable local transcription quality, repair and retry FluidAudio speaker diarization, preserve both a concise summary and a condensed detailed meeting record, and automatically archive only the document type currently generated when Notion is enabled.

**Architecture:** Keep recording and raw transcript storage unchanged. Add a model catalog/controller above WhisperKit, make FluidAudio's adapter tolerant at the CAF boundary while preserving exact manifest time, introduce a separate SwiftData record and DeepSeek pipeline for detailed minutes, and drive generation plus optional automatic archive from one two-position document slider.

**Tech Stack:** Swift 6, SwiftUI Observation, SwiftData, WhisperKit from `argmax-oss-swift`, FluidAudio 0.12.6, AVFoundation, DeepSeek chat completions, Notion REST API, and XCTest.

---

## Execution rules

- Work only in `/Users/shenminghao/Documents/会议记录app/.worktrees/codex/speaker-aware-transcription` on branch `codex/speaker-aware-transcription`.
- Use `@test-driven-development` for every production change: add one focused failing test, run it red, implement the minimum behavior, then run it green.
- Use `@systematic-debugging` instead of speculative fixes if a test fails for an unexpected reason.
- Do not modify, delete, or stage the existing untracked `.deriveddata-*` or `.sandbox-*` directories.
- Do not build a DMG, publish a GitHub release, push, or replace `/Applications/MeetingNotes.app` in this plan.
- Before the final handoff, use `@verification-before-completion` and `@code-reviewer`.

## Shared verification command

Use a fresh derived-data directory so the user's existing test artifacts remain untouched:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests
```

For Release compilation, retain the project's proven arm64-only FluidAudio flags:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes-release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
  CODE_SIGNING_ALLOWED=NO
```

### Task 1: Define and persist transcription quality modes

**Files:**
- Create: `MeetingNotes/Transcription/TranscriptionModelCatalog.swift`
- Modify: `MeetingNotes/Settings/AppSettingsStore.swift`
- Modify: `MeetingNotesTests/AppSettingsStoreTests.swift`
- Create: `MeetingNotesTests/TranscriptionModelCatalogTests.swift`

**Step 1: Write the failing settings tests**

Add cases proving the default is balanced, both raw values round-trip, and an unknown stored value falls back without crashing:

```swift
func testTranscriptionQualityDefaultsToBalanced() {
    let defaults = makeDefaults()
    let store = AppSettingsStore(defaults: defaults)

    XCTAssertEqual(store.transcriptionQualityMode, .balanced)
}

func testTranscriptionQualityPersistsHighAccuracy() {
    let defaults = makeDefaults()
    let store = AppSettingsStore(defaults: defaults)

    store.transcriptionQualityMode = .highAccuracy

    XCTAssertEqual(
        AppSettingsStore(defaults: defaults).transcriptionQualityMode,
        .highAccuracy
    )
}
```

**Step 2: Run the focused tests and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/AppSettingsStoreTests \
  -only-testing:MeetingNotesTests/TranscriptionModelCatalogTests
```

Expected: FAIL because the mode and catalog do not exist.

**Step 3: Add the pure model catalog**

Use these public shapes and keep the exact model IDs in one file:

```swift
enum TranscriptionQualityMode: String, CaseIterable, Equatable, Sendable {
    case balanced
    case highAccuracy

    var displayName: String {
        switch self {
        case .balanced: "平衡"
        case .highAccuracy: "高精度"
        }
    }
}

struct TranscriptionModelDescriptor: Equatable, Sendable {
    let mode: TranscriptionQualityMode
    let modelID: String
    let directoryName: String
    let detail: String
}

enum TranscriptionModelCatalog {
    static func descriptor(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelDescriptor {
        switch mode {
        case .balanced:
            TranscriptionModelDescriptor(
                mode: mode,
                modelID: "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page",
                directoryName: "balanced",
                detail: "默认，速度和资源占用更均衡"
            )
        case .highAccuracy:
            TranscriptionModelDescriptor(
                mode: mode,
                modelID: "openai_whisper-large-v3-v20240930_626MB",
                directoryName: "high-accuracy",
                detail: "更高多语言精度，下载和处理时间更长"
            )
        }
    }
}
```

Add `settings.transcriptionQualityMode` to `AppSettingsStore.Key`. Read unknown or missing values as `.balanced`; write the enum raw value.

**Step 4: Run the focused tests and verify green**

Expected: PASS.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionModelCatalog.swift \
  MeetingNotes/Settings/AppSettingsStore.swift \
  MeetingNotesTests/AppSettingsStoreTests.swift \
  MeetingNotesTests/TranscriptionModelCatalogTests.swift
git commit -m "feat: add transcription quality preferences"
```

### Task 2: Add safe per-model storage and legacy cache adoption

**Files:**
- Create: `MeetingNotes/Transcription/TranscriptionModelStorage.swift`
- Create: `MeetingNotesTests/TranscriptionModelStorageTests.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`

**Step 1: Write failing storage tests**

Use temporary directories and dummy `config.json` plus `.mlmodelc` directories. Cover:

```swift
func testHighAccuracyAndBalancedUseDifferentFolders() throws
func testAdoptsCompleteLegacyCacheForBalancedOnly() throws
func testExistingDestinationWinsWithoutDeletingLegacyCache() throws
func testIncompleteLegacyCacheIsNotMarkedAvailable() throws
func testFailedAdoptionLeavesLegacyCacheIntact() throws
```

The important assertions are:

```swift
XCTAssertNotEqual(
    storage.folder(for: .balanced),
    storage.folder(for: .highAccuracy)
)
XCTAssertTrue(fileManager.fileExists(atPath: legacyConfig.path))
```

The last assertion applies whenever adoption cannot finish.

**Step 2: Run the storage suite and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/TranscriptionModelStorageTests
```

Expected: FAIL because storage does not exist.

**Step 3: Implement storage without deleting valid user data**

Create a value type with explicit roots:

```swift
struct TranscriptionModelStorage: Sendable {
    let modelsRoot: URL
    let legacyModelFolder: URL?

    func folder(for mode: TranscriptionQualityMode) -> URL
    func resolvedFolder(
        for descriptor: TranscriptionModelDescriptor
    ) throws -> URL
    func hasCompleteModel(at folder: URL) -> Bool
}
```

Use `MeetingNotes/WhisperModels-v2/<directoryName>/<sanitized-model-id>` for new storage and treat the existing `MeetingNotes/WhisperModels` as legacy. Adoption rules:

1. Return the new destination if it is complete.
2. For balanced mode only, if the legacy folder is complete, atomically move it to the new destination when possible.
3. If moving fails, continue using the complete legacy folder; never partially delete it.
4. High accuracy never claims or moves the legacy folder.
5. A complete model requires `config.json` and at least one `.mlmodelc` child.

Update `AppContainer` to construct both URLs but do not yet change runtime model selection.

**Step 4: Run the storage suite and verify green**

Expected: PASS and teardown removes only test directories.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionModelStorage.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/TranscriptionModelStorageTests.swift
git commit -m "feat: isolate transcription model caches"
```

### Task 3: Make WhisperKit load the exact selected model

**Files:**
- Create: `MeetingNotes/Transcription/TranscriptionModelController.swift`
- Modify: `MeetingNotes/Transcription/WhisperKitTranscriptionService.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Create: `MeetingNotesTests/TranscriptionModelControllerTests.swift`
- Modify: `MeetingNotesTests/TranscriptionQueueTests.swift`

**Step 1: Write failing controller tests with fake engines**

Do not instantiate Core ML in unit tests. Define an injected factory and test:

```swift
func testPreparePassesBalancedModelIDAndFolder() async throws
func testHighAccuracyPassesExactLargeV3ModelID() async throws
func testDownloadedModelLoadsOfflineFromItsOwnFolder() async throws
func testChangingModeCreatesASeparateCachedService() async throws
func testConcurrentPrepareForSameModeSharesOneOperation() async throws
func testFailedHighAccuracyPreparationLeavesBalancedUsable() async throws
```

The factory spy must record a request shaped like:

```swift
struct TranscriptionModelLoadRequest: Equatable, Sendable {
    let descriptor: TranscriptionModelDescriptor
    let folder: URL
    let download: Bool
}
```

**Step 2: Run focused tests and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/TranscriptionModelControllerTests \
  -only-testing:MeetingNotesTests/TranscriptionQueueTests
```

Expected: FAIL because the controller and injected loading boundary do not exist.

**Step 3: Fix exact WhisperKit configuration first**

In `WhisperKitTranscriptionService.prepare()`, the download branch must use the instance's model:

```swift
let config = WhisperKitConfig(
    model: model,
    verbose: false,
    prewarm: true,
    load: true,
    download: true
)
```

Do not retain any production path that passes `model: nil` when the catalog supplied an ID.

**Step 4: Implement the model controller**

The controller owns one fixed-model service per mode and exposes explicit mode operations:

```swift
protocol TranscriptionModelControlling: Sendable {
    func status(for mode: TranscriptionQualityMode) async
        -> TranscriptionModelStatus
    func prepare(mode: TranscriptionQualityMode) async throws
    func service(mode: TranscriptionQualityMode) async throws
        -> any TranscriptionService
}
```

`prepare(mode:)` resolves the mode-specific folder, loads offline when complete, otherwise downloads the descriptor's exact `modelID`, copies into that folder, and updates only that mode's status. Keep failures isolated by mode.

Add an async `TranscriptionQualityPreferenceReading` adapter over `AppSettingsStore`. Change `LiveMeetingTranscriptionQueueFactory.makeQueue()` to read the mode once and request a fixed service before constructing the queue. This pins one model to the meeting's transcription queue and prevents a mid-meeting switch.

The online post-recording track pass must use the same captured mode. Add the mode to the speaker finalization call or inject the already-selected fixed service; do not read settings again during finalization.

**Step 5: Run focused tests and verify green**

Expected: PASS, including existing transcription queue ordering tests.

**Step 6: Commit**

```bash
git add MeetingNotes/Transcription/TranscriptionModelController.swift \
  MeetingNotes/Transcription/WhisperKitTranscriptionService.swift \
  MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/TranscriptionModelControllerTests.swift \
  MeetingNotesTests/TranscriptionQueueTests.swift
git commit -m "feat: load selected WhisperKit model exactly"
```

### Task 4: Expose model selection and per-mode download state in Settings

**Files:**
- Modify: `MeetingNotes/ViewModels/TranscriptionModelViewModel.swift`
- Modify: `MeetingNotes/Views/ModelStatusView.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`
- Modify: `MeetingNotes/Views/RootView.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`
- Create: `MeetingNotesTests/TranscriptionModelViewModelTests.swift`

**Step 1: Write failing view-model tests**

Cover the complete state matrix:

```swift
func testLoadShowsPersistedTranscriptionQuality() async
func testSavePersistsSelectedTranscriptionQuality() async
func testSelectingUndownloadedHighAccuracyDoesNotAutoDownload() async
func testDownloadSelectedHighAccuracyTransitionsDownloadingToReady() async
func testFailedHighAccuracyDownloadCanRetryWithoutChangingBalancedStatus() async
func testTranscriptionSelectionIsDisabledWhileMeetingIsActive() async
```

Use a fake `TranscriptionModelControlling` that records `prepare(mode:)` calls. Assert that merely assigning `.highAccuracy` records no call.

**Step 2: Run focused tests and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  -only-testing:MeetingNotesTests/TranscriptionModelViewModelTests
```

Expected: FAIL because only one global model status exists.

**Step 3: Refactor status around the selected mode**

Keep `TranscriptionModelStatus` but store status per mode. Required view-model surface:

```swift
var selectedMode: TranscriptionQualityMode { get set }
var selectedStatus: TranscriptionModelStatus { get }
var selectedDescriptor: TranscriptionModelDescriptor { get }
var canDownloadSelected: Bool { get }
func refreshStatuses() async
func prepareBalancedIfNeeded() async
func downloadSelected() async
func retrySelected() async
```

Balanced preparation may still start from `RootView.task`. High accuracy downloads only after an explicit button click.

**Step 4: Add the Settings card**

Place “本地转录精度” before the DeepSeek card. Include:

- A picker for 平衡 / 高精度.
- The descriptor detail text.
- Status icon and progress.
- “下载高精度模型” or “重试下载” when appropriate.
- A note that switching affects the next meeting.

Use accessibility IDs:

```text
settings.transcription.quality
settings.transcription.download
settings.transcription.status
```

Disable the picker and download action while the coordinator reports preparing, recording, paused, or finalizing. Keep the Notion toggle label “生成后自动归档到 Notion”, and explain that only the document type selected by the detail-page slider is archived after successful local generation.

**Step 5: Run focused tests and verify green**

Expected: PASS.

**Step 6: Commit**

```bash
git add MeetingNotes/ViewModels/TranscriptionModelViewModel.swift \
  MeetingNotes/Views/ModelStatusView.swift \
  MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotes/Views/SettingsView.swift \
  MeetingNotes/Views/RootView.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/SettingsViewModelTests.swift \
  MeetingNotesTests/TranscriptionModelViewModelTests.swift
git commit -m "feat: add transcription quality controls"
```

### Task 5: Reproduce and fix the CAF short-read diarization failure

**Files:**
- Modify: `MeetingNotes/Diarization/FluidAudioSpeakerDiarizer.swift`
- Modify: `MeetingNotesTests/FluidAudioSpeakerDiarizerTestSupport.swift`
- Modify: `MeetingNotesTests/FluidAudioSpeakerDiarizerTimelineTests.swift`

**Step 1: Add a failing 128-frame-short test**

Extend `makeSource` so a test may declare a frame count larger than the physical CAF content. Create 719,872 samples but declare 720,000 frames, matching the real failing meeting:

```swift
func testPadsSmallDecodedTailShortfallToManifestFrameCount()
    async throws {
    let physicalFrames = 719_872
    let declaredFrames: Int64 = 720_000
    let source = try makeSource(
        root: root,
        segmentSamples: [Array(repeating: 0.25, count: physicalFrames)],
        declaredFrameCounts: [declaredFrames],
        segmentStartTimes: [0]
    )

    _ = try await diarizer.diarize(source: source)

    let stitched = try XCTUnwrap(
        await converter.recordedInputSamples().first
    )
    XCTAssertEqual(stitched.count, Int(declaredFrames))
    XCTAssertEqual(stitched[physicalFrames - 1], 0.25, accuracy: 0.001)
    XCTAssertTrue(stitched[physicalFrames...].allSatisfy { $0 == 0 })
}
```

Also add tests that zero decoded frames and a shortfall above the configured safety bound fail instead of padding indefinitely.

**Step 2: Run the timeline suite and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/FluidAudioSpeakerDiarizerTimelineTests
```

Expected: FAIL with the current exact `frameLength == requested` guard.

**Step 3: Implement bounded tail padding**

Add a production limit for a small decoded tail shortfall, initially one 1,024-frame encoder packet at 48 kHz. In `appendSegment`:

1. Write every positive `buffer.frameLength` actually returned.
2. Increment `framesRead` by the actual value, not the requested value.
3. If a short read reaches EOF, compute `expectedFrames - framesRead`.
4. Reject negative or over-limit differences.
5. Use `writeSilence` for an accepted tail difference.
6. Confirm actual plus padding equals `expectedFrames` before returning.

Never loop again after a zero-length EOF read.

**Step 4: Run timeline and resource suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/FluidAudioSpeakerDiarizerTimelineTests \
  -only-testing:MeetingNotesTests/FluidAudioSpeakerDiarizerResourceTests
```

Expected: PASS with no change to gap, byte-limit, cancellation, or temporary-file cleanup behavior.

**Step 5: Commit**

```bash
git add MeetingNotes/Diarization/FluidAudioSpeakerDiarizer.swift \
  MeetingNotesTests/FluidAudioSpeakerDiarizerTestSupport.swift \
  MeetingNotesTests/FluidAudioSpeakerDiarizerTimelineTests.swift
git commit -m "fix: tolerate bounded CAF tail short reads"
```

### Task 6: Preserve actionable diarization failure stages

**Files:**
- Modify: `MeetingNotes/Diarization/SpeakerDiarizationService.swift`
- Modify: `MeetingNotes/Diarization/FluidAudioSpeakerDiarizer.swift`
- Modify: `MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift`
- Modify: `MeetingNotesTests/FluidAudioSpeakerDiarizerResourceTests.swift`
- Modify: `MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift`

**Step 1: Write the failing error-mapping tests**

Use the existing fake loader, converter, and engine to prove each stage stays distinct:

```swift
func testManifestFailureMapsToInvalidSource()
func testStitchFailureMapsToTimelineAssemblyFailed()
func testConverterFailureMapsToConversionFailed()
func testEngineFailureMapsToInferenceFailed()
func testInvalidIntervalMapsToResultValidationFailed()
func testModelPreparationFailureRemainsModelPreparationFailed()
```

In finalizer tests, assert stable stored codes such as:

```text
speaker_diarization_invalid_source
speaker_diarization_timeline_assembly_failed
speaker_diarization_conversion_failed
speaker_diarization_inference_failed
speaker_diarization_result_validation_failed
speaker_diarization_model_preparation_failed
```

**Step 2: Run focused suites and verify red**

Expected: FAIL because most errors are collapsed to `.inferenceFailed`.

**Step 3: Implement stage errors without leaking user content**

Expand the domain error:

```swift
enum SpeakerDiarizationError: Error, Equatable, Sendable {
    case modelPreparationFailed
    case invalidSource
    case timelineAssemblyFailed
    case conversionFailed
    case inferenceFailed
    case resultValidationFailed
}
```

Map only at stage boundaries and preserve `CancellationError`. Log the stage and safe numeric facts with `Logger`; do not log transcript text, audio samples, absolute paths, credentials, or model responses.

**Step 4: Run focused suites and verify green**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/FluidAudioSpeakerDiarizerResourceTests \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add MeetingNotes/Diarization/SpeakerDiarizationService.swift \
  MeetingNotes/Diarization/FluidAudioSpeakerDiarizer.swift \
  MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift \
  MeetingNotesTests/FluidAudioSpeakerDiarizerResourceTests.swift \
  MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift
git commit -m "fix: retain diarization failure stages"
```

### Task 7: Add retry-only speaker attribution for existing meetings

**Files:**
- Create: `MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Create: `MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing retry use-case tests**

Cover offline and online without any transcription service dependency:

```swift
func testOfflineRetryDiarizesMasterAndReplacesExistingTranscriptSpeakers()
    async throws
func testOnlineRetryKeepsMicrophoneAsMeAndDiarizesOnlySystemTranscript()
    async throws
func testRetryNeverCallsWhisperKitOrDeepSeek() async throws
func testRetryFailureRestoresDegradedStateWithSpecificCode() async throws
func testConcurrentRetryIsRejected() async throws
func testCompletedMeetingCanRetryAgain() async throws
```

The online fixture must start with existing transcripts tagged `.microphone` and `.system`. If an old online meeting has no usable per-track source tags, return a clear `sourceUnavailable` error rather than silently retranscribing.

**Step 2: Run retry tests and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: FAIL because retry does not exist.

**Step 3: Add atomic repository state transitions**

Add methods that can transition `.degraded` or `.completed` to `.processing`, then complete or degrade while restoring previous values if `saveContext()` fails:

```swift
func beginSpeakerDiarizationRetry(meetingID: UUID) throws
func completeSpeakerDiarizationRetry(
    meetingID: UUID,
    drafts: [AttributedTranscriptDraft],
    sourceRevision: Int
) throws
func failSpeakerDiarizationRetry(
    meetingID: UUID,
    errorCode: String
) throws
```

The completion must replace transcripts and speaker status in one isolated `ModelContext` save, not two separately observable saves.

**Step 4: Implement the retry use case**

Required surface:

```swift
@MainActor
protocol MeetingSpeakerDiarizationRetrying: AnyObject {
    func retry(meetingID: UUID) async throws
}
```

Offline flow loads `.master`, diarizes, assigns intervals to existing final transcripts, and saves. Online flow preserves microphone entries as `me`, loads `.system`, diarizes only system entries, then assembles both tracks. Use `MeetingOperationGate` so delete, generate, archive, rename, and a second retry cannot race.

**Step 5: Add detail-page retry interaction**

When state is `.degraded`, show the stage-specific short explanation plus “重新分离说话人”. While retrying, show progress and disable duplicate actions. On success reload the meeting and remove the warning. Accessibility ID:

```text
meeting.speakerDiarization.retry
```

**Step 6: Run focused suites and verify green**

Expected: PASS.

**Step 7: Commit**

```bash
git add MeetingNotes/Diarization/SpeakerDiarizationRetryUseCase.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/SpeakerDiarizationRetryUseCaseTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: retry speaker separation for saved meetings"
```

### Task 8: Persist detailed minutes independently from the concise summary

**Files:**
- Create: `MeetingNotes/Summary/MeetingDocumentModels.swift`
- Create: `MeetingNotes/Persistence/Models/DetailedMinutesRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/SummaryRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/DeepSeek/DeepSeekModels.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write failing persistence tests**

Cover creation, replacement, coexistence, rollback, and cascade deletion:

```swift
func testDetailedMinutesSaveWithoutSummary() throws
func testSummaryAndDetailedMinutesCoexist() throws
func testReplacingDetailedMinutesDoesNotChangeSummary() throws
func testFailedReplacementKeepsPreviousDetailedMinutes() throws
func testDeletingMeetingCascadesDetailedMinutes() throws
func testSummaryAndMinutesKeepIndependentArchiveStates() throws
func testRegeneratingOneDocumentResetsOnlyItsArchiveState() throws
func testLegacySummaryWithoutArchiveStateDefaultsToLocalOnly() throws
```

**Step 2: Run repository tests and verify red**

Expected: FAIL because the record and relationship do not exist.

**Step 3: Define the generated and persisted shapes**

Use strict Codable response types:

```swift
struct DetailedMinutesSection: Codable, Equatable, Sendable {
    let title: String
    let timeRange: String?
    let speakers: [String]
    let content: String
}

struct GeneratedDetailedMinutes: Codable, Equatable, Sendable {
    let overview: String
    let sections: [DetailedMinutesSection]
    let decisions: [String]
    let actionItems: [ActionItem]
    let openQuestions: [String]
}
```

`DetailedMinutesRecord` stores encoded sections/action items/open questions plus overview, model, prompt version, and `createdAt`. Add an optional cascade one-to-one relationship on `MeetingRecord`.

Define per-document archive state once and use it in both persisted records:

```swift
enum MeetingDocumentArchiveState: String, Equatable, Sendable {
    case localOnly
    case archiving
    case archived
    case failed
}
```

Add optional backing fields for archive state, the content revision successfully archived, and the last archive error code. Existing nil values read as `.localOnly`. Saving a regenerated document changes its content revision and resets only that record to `.localOnly`; it must not change the other document's state.

Repository save semantics must encode and validate everything before mutating an existing record. Add:

```swift
func saveDetailedMinutes(
    meetingID: UUID,
    generated: GeneratedDetailedMinutes,
    model: String,
    promptVersion: Int,
    createdAt: Date = .now
) throws
```

Add `DetailedMinutesRecord.self` to the repository schema. Keep all new `MeetingRecord` storage optional so the existing persistent store can use lightweight migration.

**Step 4: Run repository tests and verify green**

Expected: PASS and existing summary tests remain unchanged.

**Step 5: Commit**

```bash
git add MeetingNotes/Persistence/Models/DetailedMinutesRecord.swift \
  MeetingNotes/Summary/MeetingDocumentModels.swift \
  MeetingNotes/Persistence/Models/MeetingRecord.swift \
  MeetingNotes/Persistence/Models/SummaryRecord.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotes/DeepSeek/DeepSeekModels.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: persist detailed meeting minutes"
```

### Task 9: Build the speaker-aware, condensed detailed-minutes prompt pipeline

**Files:**
- Create: `MeetingNotes/DeepSeek/DetailedMinutesPrompt.swift`
- Modify: `MeetingNotes/DeepSeek/DeepSeekModels.swift`
- Modify: `MeetingNotes/DeepSeek/DeepSeekClient.swift`
- Modify: `MeetingNotes/DeepSeek/MeetingSummaryPrompt.swift`
- Create: `MeetingNotes/Transcription/TranscriptSpeakerLabelPolicy.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Create: `MeetingNotesTests/DetailedMinutesPromptTests.swift`
- Modify: `MeetingNotesTests/DeepSeekClientTests.swift`
- Modify: `MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift`

**Step 1: Write failing prompt and client tests**

Cover:

```swift
func testPromptIncludesTimeAndSpeakerLabels()
func testPromptRequiresCondensationInsteadOfVerbatimRestatement()
func testPromptPreservesDisagreementReasonsAndUnresolvedQuestions()
func testPromptForbidsInventedNamesOwnersDatesAndConsensus()
func testLongMeetingCreatesPartialMinutesThenOneAggregationRequest() async throws
func testTruncatedPartialResponseFailsWithoutReturningHalfDocument() async throws
func testDetailedMinutesUsesLargerOutputBudgetThanSummary() async throws
```

Inspect encoded HTTP bodies in `DeepSeekClientTests`. Assert the summary request remains at 4,096 output tokens and detailed minutes use an explicit larger budget such as 8,192.

**Step 2: Run focused suites and verify red**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/DetailedMinutesPromptTests \
  -only-testing:MeetingNotesTests/DeepSeekClientTests \
  -only-testing:MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests
```

Expected: FAIL because the prompt and client method do not exist.

**Step 3: Add a domain speaker label policy**

Move label decisions out of the SwiftUI view:

```swift
enum TranscriptSpeakerLabelPolicy {
    static func label(
        speakerID: String?,
        source: TranscriptAudioSource
    ) -> String?
}
```

Return “我”, “远端”, “远端 N”, or “说话人 N” with the current rules. `TranscriptSpeakerDisplayPolicy` should reuse this label and keep only palette behavior.

Add an explicit initializer to `MeetingTranscriptInput` with `speakerLabel: String? = nil` so existing callers and tests remain source compatible.

**Step 4: Implement the detailed-minutes two-stage prompt**

The system message must require strict JSON matching `GeneratedDetailedMinutes` and include these behavioral rules:

- Group by topic and chronology.
- Preserve material speaker positions, reasons, disagreements, decisions, action items, and unresolved questions.
- Remove greetings, filler, repeated wording, and unproductive back-and-forth.
- Merge repeated statements without changing meaning.
- Never reconstruct a verbatim transcript.
- Never invent identities, decisions, dates, owners, or consensus.
- Treat 4,000–8,000 Chinese characters for a dense two-hour meeting as guidance, not a hard quota.

For multiple input chunks, request structured partial minutes, then aggregate all partial results plus bookmarks. Never aggregate free-form truncated strings.

**Step 5: Generalize the DeepSeek request helper**

Allow `requestJSON` to receive system message, user message, response type, and max output tokens. Keep existing summary behavior byte-for-byte compatible where tests assert it. Add:

```swift
func detailedMinutes(
    input: MeetingSummaryInput,
    model: String
) async throws -> GeneratedDetailedMinutes
```

Map invalid detailed JSON to a distinct `invalidDetailedMinutesJSON` error.

**Step 6: Run focused suites and verify green**

Expected: PASS.

**Step 7: Commit**

```bash
git add MeetingNotes/DeepSeek/DetailedMinutesPrompt.swift \
  MeetingNotes/DeepSeek/DeepSeekModels.swift \
  MeetingNotes/DeepSeek/DeepSeekClient.swift \
  MeetingNotes/DeepSeek/MeetingSummaryPrompt.swift \
  MeetingNotes/Transcription/TranscriptSpeakerLabelPolicy.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotesTests/DetailedMinutesPromptTests.swift \
  MeetingNotesTests/DeepSeekClientTests.swift \
  MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift
git commit -m "feat: generate condensed detailed meeting minutes"
```

### Task 10: Orchestrate per-kind generation and optional automatic archive

**Files:**
- Modify: `MeetingNotes/Summary/MeetingDocumentModels.swift`
- Create: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift`
- Modify: `MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Create: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing orchestration tests**

Cover these accepted product rules:

```swift
func testGenerateSummarySavesThenAutoArchivesSummaryWhenEnabled() async throws
func testGenerateDetailedMinutesSavesThenAutoArchivesMinutesWhenEnabled() async throws
func testNotionDisabledStopsAfterLocalSave() async throws
func testBothDocumentsCoexistAndCanRegenerateIndependently() async throws
func testDetailedMinutesInputContainsDisplaySpeakerLabels() async throws
func testGenerationFailureKeepsPreviousDocument() async throws
func testArchiveFailureKeepsNewLocalDocument() async throws
func testRetryArchiveDoesNotCallDeepSeekAgain() async throws
func testGenerationIsAllowedAfterAPreviousArchive() async throws
func testNoFinalTranscriptRejectsEachDocumentKind() async throws
func testOperationGatePreventsGenerationAndRetryRace() async throws
```

For enabled tests, assert exactly one Notion call whose kind equals the generated kind. For disabled tests, assert zero Notion calls. No operation may request both kinds.

**Step 2: Run the new suite and verify red**

Expected: FAIL because the current action has no document-kind choice, no detailed-minutes path, and no archive-only retry.

**Step 3: Define explicit document actions**

```swift
enum MeetingDocumentKind: String, CaseIterable, Equatable, Sendable {
    case summary
    case detailedMinutes
}

enum MeetingDocumentOperation: Equatable, Sendable {
    case idle
    case generating(MeetingDocumentKind)
    case archiving(MeetingDocumentKind)
}

@MainActor
protocol MeetingDocumentManaging: AnyObject {
    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws
    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws
}
```

`generate` performs DeepSeek generation, validates the entire response, atomically saves the selected local record, and then checks `isNotionArchivingEnabled`. When enabled it archives only the same `MeetingDocumentKind`; when disabled it returns after local save. `retryArchive` loads the already-saved selected document and must never invoke DeepSeek.

Keep the old `SummarizeAndArchiving` adapter only long enough to migrate callers. Do not expose an archive selection enum or a combined “both” path.

Build transcript input from final sanitized records in chronological order and include `TranscriptSpeakerLabelPolicy.label(...)`.

Use stable states as follows:

- During generation and automatic archive, expose the current kind and stage through the view model.
- After local save with Notion disabled, leave the meeting `.summaryReady`.
- After successful automatic archive, leave the meeting `.archived`.
- If automatic archive fails, keep the new local record, return to `.summaryReady`, and expose retry for that kind.
- Generating after `.archived` moves to `.summaryReady` after local save, then returns to `.archived` only if the current kind archives successfully.
- If generation or local persistence fails, restore the previous stable state and keep the old document. Archive failure follows the separate rule above and keeps the newly saved document.

**Step 4: Run focused tests and verify green**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: PASS with exactly the per-kind Notion calls described above.

**Step 5: Commit**

```bash
git add MeetingNotes/Summary/MeetingDocumentModels.swift \
  MeetingNotes/Summary/MeetingDocumentsUseCase.swift \
  MeetingNotes/Summary/SummarizeAndArchiveUseCase.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingDocumentsUseCaseTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: auto archive the generated document kind"
```

### Task 11: Build one Notion section for the generated document kind

**Files:**
- Modify: `MeetingNotes/Summary/MeetingDocumentModels.swift`
- Modify: `MeetingNotes/Notion/NotionBlockBuilder.swift`
- Modify: `MeetingNotesTests/NotionBlockBuilderTests.swift`

**Step 1: Write failing per-kind section tests**

Required cases:

```swift
func testSummaryKindContainsSummaryAndExistingTranscriptSections()
func testSummaryKindDoesNotContainDetailedMinutes()
func testDetailedMinutesKindContainsMinutesAndNoSummaryFields()
func testBuilderAcceptsExactlyOneDocumentKindPerCall()
func testMissingRequestedDocumentIsRejectedBeforeBuildingBlocks()
func testLongMinutesParagraphsRespectNotionTextAndBatchLimits()
```

Summary must retain the existing Notion output, including bookmarks and complete transcript. Detailed minutes archive metadata and the condensed minutes without silently including the concise summary. There is no “both” kind and no builder API accepting an array of kinds.

**Step 2: Run the block-builder suite and verify red**

Expected: FAIL because content requires a summary and has no document kind.

**Step 3: Make page content kind-aware**

Refactor to optional document payloads validated at initialization:

```swift
struct NotionMeetingPageContent: Equatable, Sendable {
    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let mode: MeetingMode
    let kind: MeetingDocumentKind
    let summary: GeneratedMeetingSummary?
    let detailedMinutes: GeneratedDetailedMinutes?
    let bookmarks: [MeetingBookmarkInput]
    let transcripts: [MeetingTranscriptInput]
}
```

Validate that exactly the payload matching `kind` is present. Add `blocks(for:kind:)` or equivalent so summary and detailed minutes are independently replaceable in Task 12. Keep metadata creation separate from document-section creation.

**Step 4: Run the block-builder suite and verify green**

Expected: PASS.

**Step 5: Commit**

```bash
git add MeetingNotes/Summary/MeetingDocumentModels.swift \
  MeetingNotes/Notion/NotionBlockBuilder.swift \
  MeetingNotesTests/NotionBlockBuilderTests.swift
git commit -m "feat: build per-kind Notion document sections"
```

### Task 12: Replace only the generated kind's section on the existing Notion page

**Files:**
- Modify: `MeetingNotes/Notion/NotionModels.swift`
- Modify: `MeetingNotes/Notion/NotionClient.swift`
- Modify: `MeetingNotes/Notion/NotionArchiveService.swift`
- Modify: `MeetingNotes/Persistence/Models/ArchiveCheckpointRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/SummaryRecord.swift`
- Modify: `MeetingNotes/Persistence/Models/DetailedMinutesRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotesTests/NotionClientTests.swift`
- Modify: `MeetingNotesTests/NotionArchiveServiceTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write failing API and resume tests**

Cover:

```swift
func testAppendReturnsCreatedBlockIDs() async throws
func testArchiveBlockUsesDeleteEndpoint() async throws
func testSummaryReplacementLeavesDetailedMinutesBlockIDsUntouched() async throws
func testDetailedMinutesReplacementLeavesSummaryBlockIDsUntouched() async throws
func testSequentialKindsReuseOneMeetingPage() async throws
func testAppendFailureResumesWithoutDuplicatingCompletedBatches() async throws
func testCleanupFailureKeepsNewSectionAndCanRetryOldBlockCleanup() async throws
func testLegacyCheckpointWithoutManagedBlockIDsCanArchiveOnce() async throws
func testArchiveStateAndRevisionUpdateOnlyForRequestedKind() async throws
func testArchiveFailurePersistsFailedStateForRequestedKind() async throws
```

Use fake Notion responses containing `results[].id`. Assert the service never deletes the previous section until all new blocks for the requested kind have been appended and their IDs persisted.

**Step 2: Run focused suites and verify red**

Expected: FAIL because append returns `Void` and no section IDs are stored.

**Step 3: Extend the Notion client boundary**

Change only the block methods:

```swift
func append(
    blocks: [NotionBlockDraft],
    to pageID: String
) async throws -> [String]

func archiveBlock(id: String) async throws
```

Decode append results and send `DELETE /v1/blocks/<block-id>` for cleanup. Preserve all existing headers, timeout, cancellation, and error mapping tests.

**Step 4: Persist independently managed sections**

Add optional, Codable-backed ID arrays and a resumable pending run to `ArchiveCheckpointRecord`:

```swift
var summaryBlockIDsData: Data?
var detailedMinutesBlockIDsData: Data?
var pendingKindRawValue: String?
var pendingNewBlockIDsData: Data?
var pendingOldBlockIDsData: Data?
var pendingNextBatchIndex: Int?
```

Keep existing fields readable for lightweight migration. Repository helpers must update one checkpoint transactionally.

**Step 5: Replace one requested kind safely**

For the single `MeetingDocumentKind` passed by the generation or retry flow:

1. Reuse or create the meeting page.
2. Mark only that document `.archiving` and persist a pending run with the old managed IDs.
3. Append new blocks batch-by-batch, persisting returned IDs and the next index.
4. After all new blocks exist, promote their IDs to the active section and mark the exact local content revision `.archived`.
5. Archive the old managed blocks and clear pending cleanup state.
6. Leave the other document kind's IDs unchanged.

If any Notion step fails, mark only the requested document `.failed`, retain its new local content and pending resume data, and leave the other document state untouched. `retryArchive(kind:)` must resume from this state without calling DeepSeek.

An old page created by the previous app has no known block IDs. Do not delete unknown legacy blocks; append the first managed section once, then manage only IDs created by this version.

**Step 6: Run focused suites and verify green**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/NotionClientTests \
  -only-testing:MeetingNotesTests/NotionArchiveServiceTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests
```

Expected: PASS.

**Step 7: Commit**

```bash
git add MeetingNotes/Notion/NotionModels.swift \
  MeetingNotes/Notion/NotionClient.swift \
  MeetingNotes/Notion/NotionArchiveService.swift \
  MeetingNotes/Persistence/Models/ArchiveCheckpointRecord.swift \
  MeetingNotes/Persistence/Models/SummaryRecord.swift \
  MeetingNotes/Persistence/Models/DetailedMinutesRecord.swift \
  MeetingNotes/Persistence/MeetingRepository.swift \
  MeetingNotesTests/NotionClientTests.swift \
  MeetingNotesTests/NotionArchiveServiceTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: replace generated Notion document section"
```

### Task 13: Add the animated two-position document slider and automatic archive status

**Files:**
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Create: `MeetingNotes/Views/MeetingDocumentModeSlider.swift`
- Modify: `MeetingNotes/Summary/MeetingDocumentsUseCase.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotesTests/MeetingDocumentsUseCaseTests.swift`
- Modify: `MeetingNotesUITests/MeetingNotesUITests.swift`

**Step 1: Write failing view-model action tests**

Cover:

```swift
func testDefaultSelectedDocumentIsSummary()
func testGenerateActsOnlyOnSelectedDocument() async
func testRegenerateKeepsOldDocumentVisibleUntilSuccess() async
func testNotionEnabledAutoArchivesOnlySelectedDocument() async
func testNotionDisabledEndsWithLocalOnlyStatus() async
func testArchiveFailureKeepsBothLocalDocumentsAndOffersRetry() async
func testRetryArchiveUsesSelectedSavedDocumentWithoutGeneration() async
func testGenerateAndArchiveCannotRunConcurrently() async
```

**Step 2: Run focused tests and verify red**

Expected: FAIL because there is one combined primary action.

**Step 3: Replace the combined action model**

The view model should expose:

```swift
var selectedDocumentKind: MeetingDocumentKind
var documentOperation: MeetingDocumentOperation
var canGenerateSelectedDocument: Bool
func archiveStatus(
    for kind: MeetingDocumentKind
) -> MeetingDocumentArchiveState
func generateSelectedDocument() async
func retrySelectedDocumentArchive() async
```

`generateSelectedDocument()` passes exactly `selectedDocumentKind` to the use case. It renders generation, local-save, automatic-archive, and archive-failure stages without changing the slider selection. If the global toggle is disabled, generation stops after local save and no Notion credential validation occurs.

**Step 4: Build the dual-document card**

Keep the card before the collapsible raw transcript. Add:

- A custom two-position capsule slider with only “重点总结 / 完整纪要”.
- A moving selected background using `matchedGeometryEffect` or an equivalent geometry animation and a short spring animation such as `.spring(response: 0.28, dampingFraction: 0.84)`.
- Both click and horizontal drag selection; a drag crossing the midpoint chooses the other kind, while an incomplete drag springs back.
- Existing structured summary presentation under the first tab.
- Overview, topic sections, decisions, action items, and open questions under the second tab.
- A main button whose label is “生成重点总结 / 生成完整纪要” or “重新生成……” according to the slider and saved content.
- Progress and error state scoped to the selected document.
- Per-kind archive text: “仅本地 / 正在归档 / 已归档 / 归档失败”.
- A “重试归档到 Notion” button only when the selected document's automatic archive failed.
- No “两者” label, no manual archive menu, and no separate archive selection button.

Use accessibility IDs:

```text
meeting.documents.mode
meeting.documents.mode.summary
meeting.documents.mode.detailed
meeting.documents.generate
meeting.documents.archiveStatus
meeting.documents.retryArchive
```

Generating either document should satisfy the transcript disclosure collapse policy; update `TranscriptDisclosureContext` to test for `summary != nil || detailedMinutes != nil`.

**Step 5: Add one UI smoke flow**

Use existing launch fixtures to create a meeting with both records. Verify the slider has exactly two positions, clicking and dragging changes the visible document, the generate button follows the selected kind, and no “两者” or manual archive menu exists. Use fake DeepSeek and Notion dependencies; do not call real services.

**Step 6: Run view-model and UI tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDocumentsUseCaseTests \
  -only-testing:MeetingNotesUITests
```

Expected: PASS.

**Step 7: Commit**

```bash
git add MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/Views/MeetingDocumentModeSlider.swift \
  MeetingNotes/Summary/MeetingDocumentsUseCase.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift \
  MeetingNotesTests/MeetingDocumentsUseCaseTests.swift \
  MeetingNotesUITests/MeetingNotesUITests.swift
git commit -m "feat: add animated dual minutes generation slider"
```

### Task 14: Verify migration, regressions, and the local test app

**Files:**
- Create: `docs/testing/2026-08-02-transcription-diarization-dual-minutes-acceptance.md`
- Modify only if a failing regression proves necessary: related production or test files from Tasks 1–13

**Step 1: Run all MeetingNotes unit tests**

Run the shared verification command.

Expected: `** TEST SUCCEEDED **` with zero failures.

**Step 2: Run the full UI suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project MeetingNotes.xcodeproj \
  -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes-ui \
  -only-testing:MeetingNotesUITests
```

Expected: `** TEST SUCCEEDED **`.

**Step 3: Verify the real 128-frame regression deterministically**

Run the dedicated timeline test and confirm its fixture uses physical 719,872 versus declared 720,000 frames:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata-transcription-minutes \
  -only-testing:MeetingNotesTests/FluidAudioSpeakerDiarizerTimelineTests/testPadsSmallDecodedTailShortfallToManifestFrameCount
```

Expected: PASS.

**Step 4: Verify the copied production store before touching the real store**

Copy the user's current `default.store`, `default.store-shm`, and `default.store-wal` into a temporary test container. Launch the Debug app against the copy or add a one-shot test configuration. Verify:

- Both previously saved meetings load.
- Existing summaries remain present.
- `detailedMinutes` is nil for old meetings.
- Existing Notion page IDs and archive checkpoints remain readable.

Do not mutate the user's real store during automated migration verification.

**Step 5: Build Release arm64 without packaging**

Run the Release compilation command from this plan.

Expected: `** BUILD SUCCEEDED **`. Do not sign, package, publish, or install it.

**Step 6: Build and install only the named local test app**

Build Debug arm64 into a dedicated derived-data folder, stop any prior test instance, and copy only the built app to:

```text
/Users/shenminghao/Applications/MeetingNotes 测试版.app
```

Do not touch `/Applications/MeetingNotes.app`. Launch the test app and provide the user the clickable local path.

**Step 7: Write the manual acceptance guide**

The guide must include:

1. Confirm balanced remains default and existing model works.
2. Download high accuracy, switch, and transcribe a short Chinese sample.
3. Retry the saved approximately 28-minute failed offline meeting without retranscription.
4. Record an online meeting and verify “我” plus remote speakers.
5. Use the two-position slider to generate summary, then detailed minutes, and confirm both remain available locally.
6. Confirm a two-hour detailed result is condensed rather than verbatim.
7. With Notion enabled, generate each kind in turn and confirm only the current kind auto-archives each time.
8. With Notion disabled, verify both stay local and no Notion request occurs.
9. Restart the app and verify both documents persist.

**Step 8: Review the final diff**

Use `@code-reviewer` against the approved design and explicitly inspect:

- No audio samples, transcripts, credentials, or absolute user paths are logged.
- Model switching cannot alter an active meeting's selected service.
- Speaker retry never invokes WhisperKit or DeepSeek.
- Generation invokes Notion only after local save, only when enabled, and only for the current slider kind.
- Archive retry never invokes DeepSeek or changes the other document kind.
- Notion replacement never deletes old blocks before new blocks are persisted.
- Old summaries and stores remain compatible.

Fix only evidence-backed findings and rerun the affected focused tests.

**Step 9: Commit the acceptance guide and any verified final fixes**

```bash
git add docs/testing/2026-08-02-transcription-diarization-dual-minutes-acceptance.md
git commit -m "docs: add transcription and dual minutes acceptance guide"
```

**Step 10: Report the handoff**

Report:

- The exact test app path.
- Unit, UI, and Release build results.
- The real diarization regression test result.
- Any migration limitation or manual test still required.
- That no DMG, GitHub push, formal app replacement, or release action occurred.
