# Online Microphone Fidelity Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Store new online meetings at 48 kHz with full-level microphone audio while continuing to feed 16 kHz mixed audio to Chinese/English transcription.

**Architecture:** ScreenCaptureKit, both source converters, and the real-time mixer move to a 48 kHz storage domain. A post-mix converter derives the existing 16 kHz transcription payload, so persistence gains offline-grade fidelity without changing Whisper. The mixer preserves full microphone level and applies a window limiter only when simultaneous system and microphone audio would clip.

**Tech Stack:** Swift 6, AVFoundation, ScreenCaptureKit, Swift concurrency, XCTest, Xcode 17.

---

### Task 1: Move the online mixer to 48 kHz and preserve full microphone level

**Files:**
- Modify: `MeetingNotes/Recording/RealtimeAudioMixer.swift:13-204`
- Test: `MeetingNotesTests/RealtimeAudioMixerTests.swift:1-190`

**Step 1: Write the failing sample-rate and full-level microphone tests**

Update the test frame helper to use `RealtimeAudioMixer.sampleRate`. Change the
simultaneous-source expectation so a microphone sample of `0.2` and a system
sample of `0.6` produce `0.8`, not `0.7`. Add explicit assertions:

```swift
func testUsesPlaybackSampleRateForOnlineStorage() {
    XCTAssertEqual(
        RealtimeAudioMixer.sampleRate,
        PCMConverter.playbackSampleRate
    )
}

func testLimitsOnlyCombinedWindowsThatWouldClip() async throws {
    let mixer = RealtimeAudioMixer(windowSampleCount: 4)
    _ = try await mixer.ingest(
        frame(samples: [0.7, -0.7, 0.2, -0.2]),
        source: .microphone
    )
    let emitted = try await mixer.ingest(
        frame(samples: [0.7, -0.7, 0.2, -0.2]),
        source: .system
    )

    let frame = try XCTUnwrap(emitted.first)
    XCTAssertEqual(
        try XCTUnwrap(frame.samples.map(abs).max()),
        0.98,
        accuracy: 0.000_001
    )
    XCTAssertEqual(frame.samples[2], 0.28, accuracy: 0.000_001)
}
```

**Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/RealtimeAudioMixerTests
```

Expected: FAIL because the mixer is still 16 kHz, microphone contribution is
still 50 percent, and combined frames still use hard clipping.

**Step 3: Implement the 48 kHz full-level mix and peak limiter**

In `RealtimeAudioMixer`:

```swift
static let sampleRate = PCMConverter.playbackSampleRate
private static let maximumMixedPeak: Float = 0.98
```

Use a 960-sample default window to retain the existing 20 ms window duration.
Build the raw mixed window with microphone gain `1`. When a window contains both
sources and its peak exceeds `maximumMixedPeak`, multiply the complete window by
`maximumMixedPeak / peak`. Leave single-source windows unchanged.

**Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2.

Expected: all `RealtimeAudioMixerTests` pass with no warnings.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording/RealtimeAudioMixer.swift \
  MeetingNotesTests/RealtimeAudioMixerTests.swift
git commit -m "fix: preserve online microphone fidelity in mixer"
```

### Task 2: Add deterministic frame-to-frame transcription resampling

**Files:**
- Modify: `MeetingNotes/Recording/PCMConverter.swift:47-126`
- Test: `MeetingNotesTests/PCMConverterTests.swift`

**Step 1: Write the failing frame conversion test**

Add a test that supplies a 48 kHz mono `CapturedAudioFrame` and requests a 16 kHz
conversion:

```swift
func testConvertsCapturedFrameToTranscriptionRate() throws {
    let converter = PCMConverter(
        outputSampleRate: AudioSegmentManifest.transcriptionSampleRate,
        amplitudePolicy: .preserveAmplitude
    )
    let input = CapturedAudioFrame(
        timestamp: 1.25,
        sampleRate: PCMConverter.playbackSampleRate,
        samples: Array(repeating: 0.25, count: 4_800)
    )

    let output = try converter.convert(input)

    XCTAssertEqual(output.timestamp, 1.25)
    XCTAssertEqual(output.sampleRate, 16_000)
    XCTAssertEqual(output.channelCount, 1)
    XCTAssertEqual(output.samples.count, 1_600)
}
```

Also add rejection coverage for non-mono, empty, or invalid-rate frames.

**Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/PCMConverterTests
```

Expected: compile failure because `PCMConverter.convert(_ frame:)` does not yet
exist.

**Step 3: Implement the minimal frame conversion overload**

Add `convert(_ frame: CapturedAudioFrame) throws -> CapturedAudioFrame`. Validate
mono, finite positive sample rate, and non-empty samples. Construct a non-
interleaved Float32 `AVAudioPCMBuffer`, copy the samples, and delegate to the
existing streaming `convert(_:timestamp:)` method. Reuse
`PCMConverterError.invalidInputFormat` for invalid frames.

**Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: all `PCMConverterTests` pass with no warnings.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording/PCMConverter.swift \
  MeetingNotesTests/PCMConverterTests.swift
git commit -m "feat: resample captured frames for transcription"
```

### Task 3: Emit 48 kHz online storage frames with 16 kHz transcription payloads

**Files:**
- Modify: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift:17-32`
- Modify: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift:342-595`
- Modify: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift:597-653`
- Test: `MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift`

**Step 1: Write failing online dual-rate contract tests**

Change the configuration expectation to 48 kHz. Add a small internal helper,
`ScreenAudioTranscriptionFrameBuilder`, to the wished-for API and test:

```swift
func testBuilds16kTranscriptionPayloadWithoutChanging48kStorage() throws {
    let builder = ScreenAudioTranscriptionFrameBuilder()
    let storage = CapturedAudioFrame(
        timestamp: 0.5,
        sampleRate: PCMConverter.playbackSampleRate,
        samples: Array(repeating: 0.2, count: 4_800)
    )

    let output = try builder.build(from: storage)

    XCTAssertEqual(output.sampleRate, 48_000)
    XCTAssertEqual(output.samples, storage.samples)
    XCTAssertEqual(output.transcriptionSampleRate, 16_000)
    XCTAssertEqual(try XCTUnwrap(output.transcriptionSamples).count, 1_600)
}
```

Add lifecycle coverage proving `reset()` can be called between sessions and a
second frame still converts correctly.

**Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/ScreenAudioCaptureConfigurationTests
```

Expected: FAIL because configuration is 16 kHz and the transcription frame
builder does not exist.

**Step 3: Implement the dual-rate screen capture path**

- Set `SCStreamConfiguration.sampleRate` to 48 kHz.
- Initialize both `ScreenAudioSampleDecoder` converters with 48 kHz output and
  `.preserveAmplitude`.
- Add `ScreenAudioTranscriptionFrameBuilder`, backed by a 16 kHz
  `.preserveAmplitude` `PCMConverter`.
- Convert every mixed frame, including pause/stop/failure flush frames, before
  yielding it.
- Preserve `transcriptionSamples` and `transcriptionSampleRate` when normalizing
  output timestamps.
- Reset the transcription builder at start, stop, setup failure, start failure,
  and stream failure alongside the existing converters.

**Step 4: Run Screen and mixer tests and verify GREEN**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/ScreenAudioCaptureConfigurationTests \
  -only-testing:MeetingNotesTests/RealtimeAudioMixerTests
```

Expected: all selected tests pass with no warnings.

**Step 5: Commit**

```bash
git add MeetingNotes/Recording/ScreenAudioCaptureSource.swift \
  MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift
git commit -m "feat: add dual-rate online audio capture"
```

### Task 4: Create 48 kHz writers for new online meetings

**Files:**
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift:116-121`
- Modify: `MeetingNotesTests/MeetingCoordinatorTests.swift:720-728`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Step 1: Write the failing writer-rate test**

Extend `FakeCoordinatorWriterFactory` with an actor log of requested sample
rates. Add a test that starts one online meeting and asserts:

```swift
XCTAssertEqual(
    await fixture.writerSampleRates.values(),
    [PCMConverter.playbackSampleRate]
)
```

Keep or add the equivalent offline assertion to prove both modes share the 48
kHz storage contract.

**Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: online writer rate assertion reports 16 kHz instead of 48 kHz.

**Step 3: Use the playback sample rate for both meeting modes**

Replace the mode conditional with:

```swift
let writerSampleRate = PCMConverter.playbackSampleRate
```

Do not change coordinator transcription logic; it will read the attached 16 kHz
payload from online frames exactly as it already does for offline frames.

**Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: all `MeetingCoordinatorTests` pass with no warnings.

**Step 5: Commit**

```bash
git add MeetingNotes/Coordinator/MeetingCoordinator.swift \
  MeetingNotesTests/MeetingCoordinatorTests.swift
git commit -m "fix: store online meetings at 48 khz"
```

### Task 5: Build and prepare the manual acceptance package

**Files:**
- Verify only: all files changed above
- Update only if required: `docs/testing/manual-apple-silicon-checklist.md`

**Step 1: Run non-interactive consistency checks**

Run:

```bash
git diff --check
xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingNotesTests/PCMConverterTests \
  -only-testing:MeetingNotesTests/RealtimeAudioMixerTests \
  -only-testing:MeetingNotesTests/ScreenAudioCaptureConfigurationTests \
  -only-testing:MeetingNotesTests/MeetingCoordinatorTests
```

Expected: whitespace check succeeds and only the deterministic audio/coordinator
tests run. Do not run UI tests, do not start either meeting mode, and do not play
audio.

**Step 2: Create a fresh arm64 acceptance build**

Run:

```bash
xcodebuild build -project MeetingNotes.xcodeproj -scheme MeetingNotes \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/MeetingNotesOnlineMicAcceptance
```

Expected: `** BUILD SUCCEEDED **`.

**Step 3: Verify the package without launching it**

Run `file` on the executable and `codesign --verify --deep --strict` on the app.
Confirm arm64, no `Contents/PlugIns`, and designated requirement
`identifier "com.shenminghao.MeetingNotes"`.

**Step 4: Replace the acceptance app reversibly**

Move the previous `/Users/shenminghao/Applications/会议记录-验收版.app` to a
timestamped backup, then copy the fresh app with `ditto --rsrc --extattr`.
Re-run strict signature verification. Do not launch the app.

**Step 5: Hand off manual acceptance**

Ask the user to start an online meeting, play ordinary non-DRM system audio,
speak at normal distance, stop, and compare microphone clarity/level with a new
offline sample. Codex must not perform this acceptance.
