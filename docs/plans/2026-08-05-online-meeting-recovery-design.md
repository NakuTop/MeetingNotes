# Online Meeting Track Reconstruction and Capture Recovery Design

**Status:** Approved on 2026-08-05

## Context

Three recent online MeetingNotes recordings were inspected in the live app container. Their microphone, system-audio, and master CAF segments and manifests are present, but every persisted transcript row has a missing `sourceRawValue`. `SpeakerDiarizationRetryUseCase.retryOnline` currently rejects such rows before it looks at the physical tracks, so the UI reports that the old meeting has no usable track markers even though the source recordings exist.

The interrupted meeting `国科离子&大诚品牌建设的沟通会议` contains 77 complete segments on each of the three tracks. They end at about 19 minutes 12 seconds. macOS unified logs show that MeetingNotes remained alive, while ScreenCaptureKit was stopped at 15:22:07. The coordinator's stream-error path only sets `captureFailed` and stops the capture source; it does not stop the presentation timer, close writers, persist the interruption, or tell the user. The app therefore appeared to continue recording although no later samples were written. Audio after the last saved segment cannot be reconstructed.

## Goals

- Rebuild old online transcripts from their physical microphone and system tracks when transcript source tags are missing.
- Keep the microphone identity fixed as `me` and diarize only the system track into remote speakers.
- Never destroy the existing transcript unless a complete replacement is ready to save.
- Convert an unexpected capture-stream failure into an immediate, durable end of recording with a clear warning.
- Recover meetings left in `recording`, `paused`, or `finalizing` after relaunch by repairing every relevant manifest and making saved content usable again.
- Preserve the existing fast retry path for already source-tagged transcripts.

## Non-goals

- Recover audio that was never written after a capture stopped.
- Automatically restart ScreenCaptureKit after an unexpected failure. A restart can leave a silent gap while still appearing continuous.
- Change the three-track CAF storage format or reduce disk usage in this repair. Storage optimization should be evaluated separately.
- Automatically run a potentially long model transcription for every legacy meeting at application launch.

## Chosen Architecture

### Shared online track reconstruction

Extract the online per-track reconstruction presently embedded in `SpeakerAwareTranscriptFinalizer` into a reusable `OnlineMeetingTranscriptRebuilder` component. It will:

1. Read complete microphone and system chunks through `MeetingTrackAudioReading`.
2. Transcribe both tracks using the user's currently selected transcription model.
3. Merge chunk-level drafts per track.
4. Attribute microphone drafts to speaker `me` and source `.microphone`.
5. If diarization is requested, load and diarize only the system track and attribute its drafts to stable `remote-*` speaker IDs.
6. Assemble the two timelines and return either a complete replacement or a coarse source-tagged replacement plus a stage-specific degradation code.

`SpeakerAwareTranscriptFinalizer` and `SpeakerDiarizationRetryUseCase` will both delegate to this component. Retry keeps its existing cheap path when all transcripts already have valid microphone/system tags. When tags are missing—or an interrupted online meeting has no final transcript yet—it obtains the selected transcription service and reconstructs from the physical tracks.

The repository replacement remains atomic: reconstruction happens entirely before `completeSpeakerDiarizationRetry` replaces stored rows. Cancellation, missing files, model failure, diarization failure, or save failure leaves the old transcript intact. Missing-source messaging is used only after the required physical track manifest or segment is genuinely unavailable.

### Unexpected capture termination

The coordinator will preserve the concrete stream failure instead of swallowing it. An unexpected failure will enter a single interruption-finalization path that cannot deadlock by awaiting its own stream task. That path will:

1. Claim the lifecycle operation once so user controls cannot race the cleanup.
2. Freeze active duration immediately and stop capture-health monitoring.
3. Stop the visible timer, hide the floating recording panel, and notify the main window.
4. Finish every surviving source writer and the master writer so their final complete segments and manifests are durable.
5. Drain and finish live transcription persistence.
6. Persist the meeting as `ready`, with the actual saved duration and a stable `capture_interrupted` error marker.
7. Mark requested speaker processing as degraded/interrupted so the user can explicitly rebuild it from the saved tracks.
8. Release active resources and leave the meeting selectable, playable, summarizable, deletable, and retryable.

The notification shown to the user will state that recording stopped unexpectedly and that content before the interruption was saved. MeetingNotes will not claim that capture continued and will not silently restart it.

### Relaunch recovery

`MeetingRecoveryService` will repair all applicable manifests instead of only the master manifest. For each interrupted online meeting it will inspect master, microphone, and system manifests independently, discard manifest entries marked incomplete, and preserve all complete source files. Offline meetings continue to use only the master track.

Recovery derives the saved active duration from the longest safe complete manifest duration, preferring the master timeline when available. It transitions stranded meetings to `ready`, persists an interruption marker, and marks requested speaker processing as retryable/degraded. It does not perform model work during launch. The existing “重新分离说话人” action performs reconstruction when the user chooses it.

The root view invokes recovery once during startup before refreshing the library. Any recovered meetings are immediately visible and deletable. A concise banner tells the user that an interrupted recording was restored from locally saved content.

### User interface

- The existing orange main-window banner is reused for immediate and launch-time recovery warnings.
- `MeetingDetailViewModel` no longer treats the old source-marker error as permanently non-retryable for online meetings.
- Its warning explains that original tracks can be used to rebuild the transcript.
- Online meetings with no final mixed transcript may also retry when physical tracks exist; offline meetings still require a final transcript for re-attribution.
- Long reconstruction keeps the current progress state and operation gate, preventing simultaneous document, rename, delete, or speaker operations.

## Error Handling and Data Safety

- Physical CAF segments are never modified during transcript reconstruction.
- Recovery rewrites manifests atomically through `MeetingFileStore` and removes only incomplete manifest entries; it does not delete complete audio files.
- Existing transcript rows and speaker display names remain unchanged until a complete replacement transaction succeeds.
- Speaker display names are remapped to rebuilt speaker IDs using existing interval evidence when available.
- Capture interruption and speaker-processing failure use separate persisted codes, so a successful later speaker retry does not erase the historical fact that capture stopped early.
- Error logs record stage codes and meeting identifiers only; no transcript text, credentials, or audio samples are logged.

## Test Strategy

- Retry tests prove that an untagged legacy online meeting reconstructs from microphone/system chunks, transcribes both tracks, diarizes only system audio, and atomically replaces transcript rows.
- Failure tests prove that missing/corrupt physical tracks preserve the old transcript and persist a genuine source-unavailable state.
- No-transcript online recovery tests prove that saved source tracks can still be rebuilt.
- Coordinator tests inject a failing capture stream and verify immediate timer finish, writer finalization, persisted duration/error, user notification, and resource release without calling the normal stop control.
- Race tests verify that capture failure and a simultaneous manual stop finalize only once.
- Recovery tests cover offline master-only repair and online three-manifest repair, incomplete-tail removal, saved-duration calculation, `ready` state, and interruption marking.
- View-model tests cover the revised warning, retry-button visibility, and launch-recovery banner.
- Final verification runs focused tests first, then the complete arm64 `MeetingNotesTests` suite and an arm64 Debug build. Manual validation uses a test app only; it does not package a DMG, push GitHub, or replace the formal app unless separately requested.

## Current Data Outcome

Once this implementation is installed, the existing online meetings with intact microphone and system manifests can be rebuilt by using “重新分离说话人”. For the 大诚 meeting, only the approximately 19 minutes 12 seconds already present on disk can be processed. The later part was never written and is unrecoverable from MeetingNotes data.
