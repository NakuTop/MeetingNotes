# Speaker-Aware Transcription Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reorder the meeting detail view, add summary-aware transcript folding, preserve online microphone and system tracks, and optionally apply local FluidAudio speaker diarization.

**Architecture:** Keep the current mixed master recording and provisional live transcript as the reliability baseline. Online capture also emits synchronized microphone and system frames into independent writers; after stop, a finalizer transcribes the source tracks, optionally applies FluidAudio speaker intervals, and atomically replaces the provisional transcript. FluidAudio stays behind a small adapter so tests use deterministic fakes and all failures degrade to the existing usable meeting.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AVFoundation, ScreenCaptureKit, WhisperKit, FluidAudio 0.12.x, XCTest, Xcode 17, macOS 15 arm64.

---

### Task 1: Reorder the detail page and add summary-aware transcript folding

**Files:**
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Create: `MeetingNotesTests/TranscriptDisclosurePolicyTests.swift`

**Step 1: Write the failing disclosure-policy tests**

Create a pure policy so behavior can be verified without UI automation:

```swift
final class TranscriptDisclosurePolicyTests: XCTestCase {
    func testStartsExpandedBeforeSummaryExists() {
        XCTAssertTrue(
            TranscriptDisclosurePolicy.initialIsExpanded(hasSummary: false)
        )
    }

    func testStartsCollapsedWhenSummaryAlreadyExists() {
        XCTAssertFalse(
            TranscriptDisclosurePolicy.initialIsExpanded(hasSummary: true)
        )
    }

    func testNewSummaryCollapsesUnlessUserAlreadyInteracted() {
        XCTAssertTrue(
            TranscriptDisclosurePolicy.shouldCollapse(
                previouslyHadSummary: false,
                hasSummary: true,
                userHasInteracted: false
            )
        )
        XCTAssertFalse(
            TranscriptDisclosurePolicy.shouldCollapse(
                previouslyHadSummary: false,
                hasSummary: true,
                userHasInteracted: true
            )
        )
    }
}
```

**Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/TranscriptDisclosurePolicyTests
```

Expected: compile failure because `TranscriptDisclosurePolicy` does not exist.

**Step 3: Implement the policy and disclosure card**

Add the pure policy near `MeetingDetailView`:

```swift
enum TranscriptDisclosurePolicy {
    static func initialIsExpanded(hasSummary: Bool) -> Bool {
        !hasSummary
    }

    static func shouldCollapse(
        previouslyHadSummary: Bool,
        hasSummary: Bool,
        userHasInteracted: Bool
    ) -> Bool {
        !previouslyHadSummary && hasSummary && !userHasInteracted
    }
}
```

In `MeetingDetailView`, track the selected meeting, expansion state, prior
summary presence, and manual interaction. Reset those values when `meeting.id`
changes. Render `summarySection(meeting)` immediately after `audioSection`, then
a `DisclosureGroup("\u5b8c\u6574\u8f6c\u5f55\u5185\u5bb9", isExpanded: ...)` containing
`TranscriptView`, followed by bookmarks. When a summary first appears, collapse
only if the user has not manually changed the disclosure in this detail-view
session.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command plus:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: both selected test suites pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Views/MeetingDetailView.swift \
  MeetingNotes/Views/TranscriptView.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift \
  MeetingNotesTests/TranscriptDisclosurePolicyTests.swift
git commit -m "feat: prioritize summary and fold full transcript"
```

### Task 2: Add the default-off experiment setting and meeting snapshot

**Files:**
- Modify: `MeetingNotes/Settings/AppSettingsStore.swift`
- Modify: `MeetingNotes/ViewModels/SettingsViewModel.swift`
- Modify: `MeetingNotes/Views/SettingsView.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotesTests/AppSettingsStoreTests.swift`
- Modify: `MeetingNotesTests/SettingsViewModelTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write failing preference and snapshot tests**

Add coverage for a new key that is absent by default:

```swift
func testSpeakerDiarizationDefaultsToDisabled() {
    XCTAssertFalse(store.isSpeakerDiarizationEnabled)
}

func testPersistsSpeakerDiarizationPreference() {
    store.isSpeakerDiarizationEnabled = true
    XCTAssertTrue(AppSettingsStore(defaults: defaults).isSpeakerDiarizationEnabled)
}
```

Add coordinator/repository coverage proving that a meeting created while the
preference is enabled stores `speakerDiarizationRequested == true`, and that a
later settings change does not mutate that meeting.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/AppSettingsStoreTests \
  -only-testing:MeetingNotesTests/SettingsViewModelTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: compile failures for the missing preference and meeting property.

**Step 3: Implement the setting and persisted snapshot**

Add a default-off setting:

```swift
private enum Key {
    static let speakerDiarizationEnabled =
        "settings.speakerDiarizationEnabled"
}

var isSpeakerDiarizationEnabled: Bool {
    get {
        access(keyPath: \AppSettingsStore.isSpeakerDiarizationEnabled)
        return defaults.bool(forKey: Key.speakerDiarizationEnabled)
    }
    set {
        withMutation(keyPath: \AppSettingsStore.isSpeakerDiarizationEnabled) {
            defaults.set(newValue, forKey: Key.speakerDiarizationEnabled)
        }
    }
}
```

Expose the value through `SettingsViewModel.load()` and `save()`. Add a
separate `AdaptiveGlassCard` titled "\u8bd5\u9a8c\u529f\u80fd" with a toggle titled
"FluidAudio \u8bf4\u8bdd\u4eba\u5206\u79bb" and explanatory text.

Add `speakerDiarizationRequested = false`, processing-state raw value, and an
optional safe error code to `MeetingRecord`, using migration-safe defaults.
Extend `createMeeting` and `MeetingLifecycleRepository.createMeeting` to accept
the snapshot. Add a small `SpeakerDiarizationPreferenceReading` protocol to
coordinator dependencies; the live dependency uses `AppSettingsStore` and
tests use a fixed fake.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass and existing Notion
preference tests remain unchanged.

**Step 5: Commit**

```bash
git add MeetingNotes/Settings MeetingNotes/ViewModels/SettingsViewModel.swift \
  MeetingNotes/Views/SettingsView.swift MeetingNotes/Persistence \
  MeetingNotes/Coordinator MeetingNotesTests/AppSettingsStoreTests.swift \
  MeetingNotesTests/SettingsViewModelTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: add speaker diarization experiment setting"
```

### Task 3: Make audio manifests and writers track-aware

**Files:**
- Modify: `MeetingNotes/Recording/AudioSegmentManifest.swift`
- Modify: `MeetingNotes/Recording/MeetingFileStore.swift`
- Modify: `MeetingNotes/Recording/SegmentedPCMWriter.swift`
- Modify: `MeetingNotes/Playback/MeetingAudioSourceLoader.swift`
- Modify: `MeetingNotesTests/MeetingFileStoreTests.swift`
- Modify: `MeetingNotesTests/SegmentedPCMWriterTests.swift`
- Modify: `MeetingNotesTests/MeetingAudioSourceLoaderTests.swift`

**Step 1: Write failing track naming and legacy-compatibility tests**

Define the desired mapping in tests:

```swift
func testTrackFileNamesKeepMasterBackwardCompatible() {
    XCTAssertEqual(AudioTrack.master.manifestFileName, "manifest.json")
    XCTAssertEqual(AudioTrack.master.segmentPrefix, "segment")
    XCTAssertEqual(
        AudioTrack.microphone.manifestFileName,
        "microphone-manifest.json"
    )
    XCTAssertEqual(AudioTrack.system.segmentPrefix, "system-segment")
}
```

Create master, microphone, and system writers for one meeting and assert that
each manifest contains only its own segment names. Add a loader test proving
`load(meetingID:)` still defaults to the master manifest.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/MeetingFileStoreTests \
  -only-testing:MeetingNotesTests/SegmentedPCMWriterTests \
  -only-testing:MeetingNotesTests/MeetingAudioSourceLoaderTests
```

Expected: compile failure because `AudioTrack` and track-aware overloads do not
exist.

**Step 3: Implement track-aware paths**

Add:

```swift
enum AudioTrack: String, CaseIterable, Codable, Sendable {
    case master
    case microphone
    case system

    var manifestFileName: String {
        switch self {
        case .master: "manifest.json"
        case .microphone: "microphone-manifest.json"
        case .system: "system-manifest.json"
        }
    }

    var segmentPrefix: String {
        switch self {
        case .master: "segment"
        case .microphone: "microphone-segment"
        case .system: "system-segment"
        }
    }
}
```

Add `track: AudioTrack = .master` parameters to manifest save/load, writer
initialization, and audio source loading. Preserve existing call sites through
default parameters. Use `track.segmentPrefix` when opening CAF files and
`track.manifestFileName` when atomically saving manifests.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass, including legacy
master loading.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording MeetingNotes/Playback/MeetingAudioSourceLoader.swift \
  MeetingNotesTests/MeetingFileStoreTests.swift \
  MeetingNotesTests/SegmentedPCMWriterTests.swift \
  MeetingNotesTests/MeetingAudioSourceLoaderTests.swift
git commit -m "feat: support per-track meeting audio manifests"
```

### Task 4: Emit synchronized master and source frames from capture

**Files:**
- Modify: `MeetingNotes/Recording/CapturedAudioFrame.swift`
- Modify: `MeetingNotes/Recording/AudioCaptureSource.swift`
- Modify: `MeetingNotes/Recording/MicrophoneCaptureSource.swift`
- Modify: `MeetingNotes/Recording/RealtimeAudioMixer.swift`
- Modify: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift`
- Modify: `MeetingNotesTests/MicrophoneCaptureSourceTests.swift`
- Modify: `MeetingNotesTests/RealtimeAudioMixerTests.swift`
- Modify: `MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift`

**Step 1: Write failing packet and mixer tests**

Specify the capture contract:

```swift
struct CapturedAudioPacket: Equatable, Sendable {
    let master: CapturedAudioFrame
    let sourceFrames: [AudioTrack: CapturedAudioFrame]
}
```

Update mixer tests to assert that a window containing microphone `[0.2, 0.4]`
and system `[0.6, 0.2]` emits:

- master `[0.8, 0.6]`
- microphone `[0.2, 0.4]`
- system `[0.6, 0.2]`

Also assert that a missing source is represented by an equal-length silence
window so source files keep the master timeline. The microphone-only capture
test should emit a packet with no duplicate source track.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/MicrophoneCaptureSourceTests \
  -only-testing:MeetingNotesTests/RealtimeAudioMixerTests \
  -only-testing:MeetingNotesTests/ScreenAudioCaptureConfigurationTests
```

Expected: compile failures while the capture stream still yields one frame.

**Step 3: Implement packet emission**

Change `AudioCaptureSource.start()` to yield `CapturedAudioPacket`.
`MicrophoneCaptureSource` wraps its current frame as `master` with an empty
source dictionary.

Refactor the mixer bucket to produce averaged microphone and system arrays
before combining them. Build the limiter-adjusted master exactly as today, but
keep source arrays unscaled. Emit both source frames for every online master
window, filling absent source samples with zero. Normalize one packet timestamp
in `ScreenAudioCaptureSource`, add the 16 kHz transcription payload only to the
master, and preserve source frame timestamps and 48 kHz samples.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass, including pause,
flush, FIFO, limiter, and timestamp normalization coverage.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording MeetingNotesTests/MicrophoneCaptureSourceTests.swift \
  MeetingNotesTests/RealtimeAudioMixerTests.swift \
  MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift
git commit -m "feat: emit synchronized online source tracks"
```

### Task 5: Write online source tracks without risking the master recording

**Files:**
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write failing coordinator routing and degradation tests**

Extend the fake writer factory to record requested tracks and provide one fake
per track. Assert:

- offline start requests only `.master`;
- online start requests `.master`, `.microphone`, and `.system`;
- one packet writes the master and both sources with the same normalized
  timestamp;
- a source writer append failure does not stop later master writes or set
  `captureFailed`;
- a master writer failure keeps the existing capture-failure behavior.

**Step 2: Run the coordinator suite and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: compile failures for track-aware writer requests and packet routing.

**Step 3: Implement multi-writer lifecycle handling**

Change the factory contract to:

```swift
func makeWriter(
    meetingID: UUID,
    track: AudioTrack,
    sampleRate: Double
) async throws -> any MeetingAudioWriting
```

Store the master writer separately and source writers in
`[AudioTrack: any MeetingAudioWriting]`. Create source writers only for online
meetings. Normalize the packet using the master sample count; write matching
source frames at that same timestamp. On a source error, best-effort finish and
remove only that writer, then persist a safe degradation code. On stop, finish
all surviving source writers before post-processing. Ensure start rollback and
resource release finish every writer exactly once.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all coordinator tests pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Coordinator MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: persist online microphone and system tracks"
```

### Task 6: Add attributed transcripts and atomic final replacement

**Files:**
- Modify: `MeetingNotes/Transcription/TranscriptionService.swift`
- Create: `MeetingNotes/Transcription/SpeakerTranscriptAssembler.swift`
- Modify: `MeetingNotes/Persistence/Models/TranscriptRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Create: `MeetingNotesTests/SpeakerTranscriptAssemblerTests.swift`
- Modify: `MeetingNotesTests/MeetingRepositoryTests.swift`

**Step 1: Write failing assembler and rollback tests**

Introduce the desired value types in tests:

```swift
enum TranscriptAudioSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
    case room
}

struct AttributedTranscriptDraft: Equatable, Sendable {
    let transcript: TranscriptDraft
    let speakerID: String?
    let source: TranscriptAudioSource
}
```

Test chronological merging with overlapping local and remote entries, stable
tie-breaking, whitespace filtering, and no cross-source boundary de-duplication.
Add a repository test that injects a save failure and proves old transcripts
remain after `replaceTranscripts` fails.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/SpeakerTranscriptAssemblerTests \
  -only-testing:MeetingNotesTests/MeetingRepositoryTests
```

Expected: compile failures for the attributed draft and replacement method.

**Step 3: Implement identity persistence and atomic replacement**

Add an optional `sourceRawValue` to `TranscriptRecord` for migration safety and
a computed source fallback of `.mixed`. Implement
`SpeakerTranscriptAssembler` to sanitize and sort attributed drafts without
removing valid simultaneous text.

Implement `replaceTranscripts(meetingID:drafts:sourceRevision:)` by staging new
records, preserving the old array, and restoring it if `saveContext()` throws.
Expose the operation through `MeetingLifecycleRepository` so the coordinator or
finalizer never mutates SwiftData directly.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: both suites pass and existing append behavior
still stores `.mixed`/nil-compatible rows.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription MeetingNotes/Persistence \
  MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift \
  MeetingNotesTests/SpeakerTranscriptAssemblerTests.swift \
  MeetingNotesTests/MeetingRepositoryTests.swift
git commit -m "feat: persist attributed transcript revisions"
```

### Task 7: Build coarse source-track finalization without FluidAudio

**Files:**
- Create: `MeetingNotes/Transcription/MeetingTrackAudioReader.swift`
- Create: `MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift`
- Modify: `MeetingNotes/Playback/MeetingAudioSourceLoader.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Create: `MeetingNotesTests/MeetingTrackAudioReaderTests.swift`
- Create: `MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write failing reader and online finalizer tests**

Define a streaming reader that yields 16 kHz chunks with absolute offsets:

```swift
struct MeetingAudioSampleChunk: Equatable, Sendable {
    let samples: [Float]
    let startingAt: TimeInterval
}
```

Test reading across two CAF segments, resampling 48 kHz to 16 kHz, preserving
the absolute timeline, and bounding each yielded chunk. With fake readers and
transcription services, test that online finalization produces `me` microphone
drafts and `remote` system drafts, then merges them chronologically. A failure
on either required track must return a fallback outcome without replacement.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/MeetingTrackAudioReaderTests \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: compile failures for the reader and finalizer protocols.

**Step 3: Implement streaming source transcription**

Generalize `MeetingAudioSourceLoader.load(meetingID:track:)` from Task 3.
`MeetingTrackAudioReader` opens one validated CAF segment at a time, converts
buffers through a persistent 16 kHz `PCMConverter`, and yields bounded chunks.

Add:

```swift
protocol MeetingSpeakerFinalizing: Sendable {
    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome
}
```

For online meetings, transcribe microphone and system chunks sequentially
through the shared `TranscriptionService`, merge each track with
`TranscriptMerger`, attribute coarse identities, and return one complete
replacement revision. With diarization still unavailable, record a degraded
coarse result when requested. Offline meetings with the setting off return
`.unchanged`.

Wire the finalizer after master/source writers and provisional transcription
finish but before `finalizeMeeting`. Only call repository replacement for a
complete replacement result. Keep the meeting usable on `.unchanged` or
`.degraded`.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected suites pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Transcription MeetingNotes/Playback \
  MeetingNotes/Coordinator MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/MeetingTrackAudioReaderTests.swift \
  MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "feat: finalize online transcripts from source tracks"
```

### Task 8: Integrate FluidAudio behind a diarization adapter

**Files:**
- Modify: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify: `MeetingNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `MeetingNotes/Diarization/SpeakerDiarizationService.swift`
- Create: `MeetingNotes/Diarization/FluidAudioSpeakerDiarizer.swift`
- Create: `MeetingNotes/Diarization/SpeakerIntervalAssigner.swift`
- Modify: `MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Create: `MeetingNotesTests/SpeakerIntervalAssignerTests.swift`
- Modify: `MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift`

**Step 1: Write failing interval-assignment tests**

Use library-independent domain values:

```swift
struct SpeakerInterval: Equatable, Sendable {
    let rawSpeakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}
```

Test greatest-overlap assignment, deterministic tie-breaking, no-overlap
fallback, first-appearance numbering, online `remote-N`, and offline `room-N`.
Test finalizer behavior for diarizer success, model failure, and inference
failure using a fake `SpeakerDiarizing` protocol.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/SpeakerIntervalAssignerTests \
  -only-testing:MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests
```

Expected: compile failure because the diarization domain types are missing.

**Step 3: Implement and verify the library adapter**

Add the Swift package from the official repository, pinned to the compatible
`0.12` minor line:

```text
https://github.com/FluidInference/FluidAudio.git
```

Link only the `FluidAudio` product to the app target. Resolve dependencies and
inspect the pinned checkout's public declarations before writing the adapter:

```bash
xcodebuild -resolvePackageDependencies \
  -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -derivedDataPath .deriveddata
rg -n "public (actor|class|protocol).*Diar|process\(audioSource" \
  .deriveddata/SourcePackages/checkouts/FluidAudio
```

Keep all imported FluidAudio types inside `FluidAudioSpeakerDiarizer`. Adapt the
pinned `OfflineDiarizerManager` model preparation and disk-backed processing API
to:

```swift
protocol SpeakerDiarizing: Sendable {
    func diarize(
        source: MeetingAudioSource
    ) async throws -> [SpeakerInterval]
}
```

Use FluidAudio's documented disk-backed `StreamingAudioSampleSource` path for
long meetings and convert the result immediately into app-owned intervals.
Do not expose FluidAudio model or result types elsewhere. Persist models under
`Application Support/MeetingNotes/FluidAudioModels` and allow the official
manager to prepare/download them lazily.

Implement `SpeakerIntervalAssigner` and update the finalizer:

- online experiment on: diarize `.system`, assign `remote-N`, keep microphone
  as `me`;
- offline experiment on: diarize `.master`, assign `room-N` to provisional
  master transcripts;
- diarization error: use coarse online result or unchanged offline transcript
  and store a safe error code.

**Step 4: Run focused tests, resolve packages, and verify GREEN**

Run the Step 2 command. Then run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: selected tests pass, package resolves at the pinned version, and the
arm64 Debug app builds without warnings introduced by this task.

**Step 5: Commit**

```bash
git add MeetingNotes.xcodeproj MeetingNotes/Diarization \
  MeetingNotes/Transcription/SpeakerAwareTranscriptFinalizer.swift \
  MeetingNotes/App/AppContainer.swift \
  MeetingNotesTests/SpeakerIntervalAssignerTests.swift \
  MeetingNotesTests/SpeakerAwareTranscriptFinalizerTests.swift
git commit -m "feat: add local FluidAudio speaker diarization"
```

### Task 9: Present speaker identities and processing degradation in the UI

**Files:**
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Persistence/Models/MeetingRecord.swift`
- Modify: `MeetingNotes/Persistence/MeetingRepository.swift`
- Create: `MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Write failing speaker-display and warning tests**

Specify a library-independent presentation value:

```swift
struct TranscriptSpeakerBadge: Equatable, Sendable {
    let label: String
    let paletteIndex: Int
    let isLocalUser: Bool
}
```

Test `me -> \u6211`, `remote -> \u8fdc\u7aef`, `remote-2 -> \u8fdc\u7aef 2`, and
`room-3 -> \u8bf4\u8bdd\u4eba 3`. Test stable palette indexes and nil badges for unknown
mixed transcripts. Add view-model tests mapping stored safe failure codes to a
non-blocking Chinese warning and dismissal behavior.

**Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests
```

Expected: compile failure for the badge policy and speaker warning API.

**Step 3: Implement transcript badges and processing status**

Include `speakerID` and transcript source in `TranscriptDisplayEntry`. Render a
compact badge between the timecode and text. Use a fixed accent style for `me`
and a deterministic palette index for numbered speakers. Keep rows without a
known identity visually unchanged.

Expose persisted speaker-processing state from `MeetingDetailViewModel`.
Show a compact progress/status line while enrichment is active and a
dismissible warning when the meeting used a fallback. Do not disable playback,
summary, local storage, or Notion actions because of a speaker-processing
warning.

**Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: both suites pass.

**Step 5: Commit**

```bash
git add MeetingNotes/Views MeetingNotes/ViewModels/MeetingDetailViewModel.swift \
  MeetingNotes/Persistence MeetingNotesTests/TranscriptSpeakerDisplayPolicyTests.swift \
  MeetingNotesTests/MeetingDetailViewModelTests.swift
git commit -m "feat: display speaker-aware meeting transcripts"
```

### Task 10: Run regression verification and update manual acceptance notes

**Files:**
- Modify: `docs/testing/manual-apple-silicon-checklist.md`
- Verify: all implementation files from Tasks 1-9

**Step 1: Update the manual checklist**

Add checks for:

- detail order and summary-triggered transcript folding;
- online `\u6211/\u8fdc\u7aef` with the experiment off;
- online numbered remote speakers with the experiment on;
- offline numbered speakers with the experiment on;
- first-use FluidAudio model preparation and offline reuse;
- master playback after source-track or diarization degradation;
- legacy meeting playback.

**Step 2: Run static consistency checks**

Run:

```bash
git diff --check
rg -n "FluidAudio|speakerDiarization|CapturedAudioPacket|AudioTrack" \
  MeetingNotes MeetingNotesTests docs/testing
```

Expected: no whitespace errors and all new concepts appear only in their
intended layers.

**Step 3: Run the full test suite**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: all `MeetingNotesTests` pass. UI tests may remain excluded unless a
configured test host and permissions are available.

**Step 4: Build the Debug app**

Run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .deriveddata CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Expected: `** BUILD SUCCEEDED **` and the product exists at
`.deriveddata/Build/Products/Debug/MeetingNotes.app`.

**Step 5: Review the complete change**

Use `@requesting-code-review` against the approved design. Address only
verified defects, then rerun the affected focused tests and the full build.

**Step 6: Commit documentation or final corrections**

```bash
git add docs/testing/manual-apple-silicon-checklist.md
git commit -m "docs: add speaker diarization acceptance checks"
```

**Step 7: Stop before DMG or GitHub publication**

Report the Debug app path and verification results. Do not build a DMG, merge,
push, or create a pull request until the user requests the final publication
round.
