# Formal-Feature Audio Beta Design

**Status:** Approved on 2026-08-19

## Context

The production `v1.1.1` application is the accepted functional baseline. The existing microphone-compatibility Beta proved the new audio-device discovery, fallback capture, adaptive recovery, and smart-diagnostic behavior on the development Mac, but its accumulated branch also contains transcription and model-storage experiments that must not replace otherwise working production behavior.

This candidate therefore starts from production commit `234ff1be37109cdd19f916328d2857954c4f81ba` and ports only the already reviewed audio-device and smart-diagnostic changes. The existing dirty Batch 9–16 worktree remains untouched as source evidence.

## Goals

- Preserve all accepted production `v1.1.1` meeting, transcription, archive, settings, and UI behavior unless a change is strictly required by the audio update.
- Port AVFoundation microphone capture with Core Audio HAL discovery/fallback, AUHAL capture, adaptive runtime recovery, and independent online microphone capture.
- Port the accepted smart-diagnostic deadlines, hard timeout/cancellation gate, stage-specific safe reports, preview, consent, and DeepSeek entry.
- Preserve the working balanced-model cache identity while making a fresh installation able to resolve, download, install, prewarm, load, and transcribe with the same model.
- Change the high-accuracy model to `openai_whisper-large-v3` as explicitly requested.
- Produce an isolated Beta `1.2.0 (12)` for packaged-app retesting without modifying production `1.1.1 (3)`.

## Non-goals

- Do not port the experimental `small_216MB` selector.
- Do not port the exact-manifest legacy-cache migration introduced after the production baseline.
- Do not change PCM gain, language detection, decoding defaults, transcription chunk duration, transcript merging, diarization, persistence, or meeting workflows.
- Do not redesign the microphone or diagnostic architecture.
- Do not merge to `main`, replace production artifacts, or claim affected-hardware acceptance before the user tests the packaged candidate.

## Selected Architecture

### Clean production baseline

All implementation work occurs in the isolated branch `codex/formal-audio-beta-1.2.0`, created from `main`/`v1.1.1`. The existing test branch and its uncommitted Batch 9–16 changes are read-only sources. Audio changes are selected file-by-file and reviewed against both the production baseline and the validated Beta behavior.

### Audio-only integration boundary

The candidate includes only these functional areas:

1. Dual microphone-device discovery through AVFoundation and Core Audio.
2. Core Audio AUHAL microphone capture fallback.
3. Adaptive primary/fallback selection, caller cancellation, stale-token isolation, stop/restart safety, and topology recovery.
4. Online ScreenCaptureKit system-audio capture plus a separate adaptive microphone provider.
5. Smart diagnostic microphone/system stages with 3-second observation windows and hard total deadlines of 12 and 15 seconds.
6. The single-terminal timeout gate, including buffered cancellation before continuation registration and rejection/cancellation of late task installation.
7. Safe schema-v2 diagnostic reports for success, failure, and timeout, with preview, explicit consent, and DeepSeek upload entry.

No transcription pipeline behavior is imported merely because it exists in the accumulated Beta worktree.

### Model identity and download routing

`TranscriptionModelDescriptor` gains a distinct remote download selector so persistent cache identity no longer has to double as a Hugging Face folder query.

Balanced mode uses:

- Persistent/logical model ID: `openai_whisper-large-v3_turbo_v3_1747_1_10_256Page`
- Remote download selector: `openai_whisper-large-v3-v20240930_turbo`
- Persistent directory: the existing `balanced` layout and encoded model-ID folder

This keeps the existing working production cache address stable while directing a new machine to the current public WhisperKit Core ML folder containing the same verified key model artifacts.

High-accuracy mode uses:

- Persistent/logical model ID: `openai_whisper-large-v3`
- Remote download selector: `openai_whisper-large-v3`
- Persistent directory: the existing `high-accuracy` layout

The previous `openai_whisper-large-v3-v20240930_626MB` cache remains untouched on disk but is not treated as the newly selected high-accuracy model.

The controller passes the remote selector only when a download is required. Once a complete model is installed in the app-owned destination, the existing offline load path uses the resolved local folder with `download: false`.

### Distribution identity

Production remains:

- Display name: `会议记录`
- Bundle ID: `com.shenminghao.MeetingNotes`
- Version/build: `1.1.1 (3)`

The candidate Beta is:

- Display name: `会议记录 Beta`
- Bundle ID: `com.shenminghao.MeetingNotes.beta`
- Version/build: `1.2.0 (12)`

The Xcode project is edited manually; `xcodegen` is not run. Existing package references, especially FluidAudio and the pinned WhisperKit package, must remain intact.

## Data, Privacy, and Compatibility

- Model downloads use WhisperKit's existing public Hugging Face path and the app's network-client entitlement.
- No user audio, transcript, credential, device UID, Core Audio UID, username, or absolute path enters diagnostic upload JSON.
- Raw diagnostic errors remain local and are reduced to allowlisted stage outcomes and issue codes before upload.
- Existing production model files are never deleted as part of selector resolution or candidate validation.
- Fresh-model validation uses a separate temporary/cache destination so it does not obtain a false pass from the developer Mac's already-installed model.

## Validation Strategy

1. Prove the untouched production baseline passes its unit suite before integration.
2. Port each bounded audio layer with its focused tests and preserve all existing production tests.
3. Add model-catalog/controller tests proving the distinction between local identity and remote selector and the requested high-accuracy identity.
4. Run focused audio, diagnostics, settings, and model tests.
5. Run a Debug build, full `MeetingNotesTests`, and whole-scheme tests, reporting exact exit codes and UI-test results.
6. Use a clean temporary model environment to resolve, download, persist, prewarm/load, and transcribe locally with the balanced selector. Validate `openai_whisper-large-v3` resolution and, where practical, its complete preparation without changing the user's saved preference.
7. Package `MeetingNotes-1.2.0-beta-build12.dmg`; verify hash, DMG integrity, mounted identity, entitlements, privacy string, and code signature.
8. Treat actual packaged-app microphone/diagnostic/model smoke and affected-hardware validation as human gates. Automated tests do not substitute for those checks.
9. If no usable Developer ID signing identity/notarization path exists, report that other-Mac Gatekeeper distribution is not fully proven rather than claiming normal download-and-run behavior.

## Acceptance Criteria

- The candidate diff against production contains only the reviewed audio/diagnostic integration, narrow model download routing, model selector update, Beta configuration, tests, and release documentation.
- All automated validation exits successfully with zero deterministic test failures.
- A clean model environment proves that balanced mode no longer depends on a developer-machine legacy cache.
- High accuracy is exactly `openai_whisper-large-v3` in catalog, controller request, and user-facing preparation flow.
- The packaged Beta is `1.2.0 (12)` and production identity remains byte-for-byte unchanged in its configuration.
- The result remains a Beta pending packaged-app human retest and affected-hardware validation.
