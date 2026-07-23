# Speaker-Aware Transcription and Detail Layout Design

## Goal

Improve the meeting detail hierarchy and add speaker-aware transcripts without
placing recording reliability at risk.

The change has four user-visible outcomes:

1. Move "总结与归档" directly below the local recording player and before the
   full transcript.
2. Make the full transcript collapsible. It remains expanded before a summary
   exists and defaults to collapsed after a summary is generated.
3. Preserve separate microphone and system-audio tracks for online meetings so
   local microphone speech is always labelled "我" and system audio is labelled
   as remote speech.
4. Add an opt-in experimental FluidAudio speaker-diarization setting for remote
   online audio and offline meetings.

## Confirmed Product Decisions

- Use a mixed master track plus source tracks and perform identity enrichment
  after the meeting stops.
- Source-track recording is always enabled for new online meetings.
- FluidAudio speaker diarization defaults to off.
- The setting is snapshotted when a meeting starts. Changing it during a
  meeting affects only the next meeting.
- With the experiment off, online transcripts distinguish "我" and "远端".
- With the experiment on, the system track is split into "远端 1", "远端 2",
  and so on. Offline meetings use "说话人 1", "说话人 2", and so on.
- Speaker numbering is stable only within one meeting and follows first
  appearance. Cross-meeting voice identity and manual speaker renaming are out
  of scope.
- Existing meetings are not automatically reprocessed.

## Chosen Architecture

### Why post-meeting enrichment

Three implementation routes were considered:

1. Preserve source tracks and enrich identities after recording.
2. Run dual-track transcription and streaming diarization during recording.
3. Keep only the mixed track and infer identities from mixed timestamps.

The first route is selected. It keeps the current recording path responsive,
preserves an authoritative playback file, and produces more reliable source
identity than mixed-audio guessing. Real-time multi-model processing would add
substantial CPU, memory, correction, and lifecycle complexity. Mixed-only
inference cannot reliably distinguish simultaneous local and remote speech.

### Online meeting tracks

Every new online meeting has three logical tracks:

- `master`: the existing microphone plus system-audio mix used for playback and
  recovery compatibility.
- `microphone`: the local microphone only. Its transcript speaker is always
  `me`, displayed as "我".
- `system`: ScreenCaptureKit system audio only. With diarization disabled it is
  displayed as "远端"; with diarization enabled it receives numbered remote
  speaker identifiers.

The capture layer will emit a synchronized packet containing the mixed storage
frame and any source frames that contributed to it. The coordinator continues
to write and transcribe the master frame during recording while independently
writing source frames. Source-track write failures must not stop the master
writer.

### Offline meeting track

Offline meetings keep their existing master microphone recording and do not
duplicate it into a second file. When experimental diarization is enabled, the
master recording is also the diarization input.

### Final transcript processing

During recording, the existing mixed transcript remains a provisional result.
After capture and all writers finish:

1. Transcribe the microphone and system tracks independently for online
   meetings.
2. Label every microphone transcript segment as `me`.
3. If diarization is disabled, label every system transcript segment as the
   coarse `remote` speaker.
4. If diarization is enabled, run FluidAudio on the system track and assign each
   transcript segment to the speaker interval with the greatest overlap.
5. For an offline meeting with diarization enabled, run the same overlap
   assignment against the master transcript.
6. Merge source transcripts chronologically. Overlapping local and remote
   entries remain separate instead of discarding either side.
7. Atomically replace provisional transcripts only after the complete final
   result is ready.

FluidAudio accepts 16 kHz mono Float32 input. Its disk-backed streaming input
will be used for long meetings so the complete recording does not need to be
materialized in memory. The app target already requires macOS 15 on Apple
Silicon, which is compatible with FluidAudio's documented offline diarization
requirements.

Official references:

- <https://github.com/FluidInference/FluidAudio>
- <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md>

## Storage and Persistence

### Audio files

`manifest.json` remains the master manifest so existing playback, waveform,
recovery, and deletion behavior remains compatible.

Online meetings add track-specific manifests and source-prefixed CAF segments:

- `microphone-manifest.json` and `microphone-segment-####.caf`
- `system-manifest.json` and `system-segment-####.caf`

The existing segment format and 48 kHz mono storage contract are reused.
FluidAudio input is resampled to 16 kHz at the processing boundary.

### Settings snapshot and processing state

`AppSettingsStore` gains a default-off speaker-diarization preference. Each new
meeting persists a snapshot of whether diarization was requested so a restart
or a later setting change cannot alter in-flight behavior.

The meeting record also persists speaker-processing state and a non-sensitive
failure code. This prevents a meeting from remaining indefinitely in a
processing state and allows the detail view to explain a degraded result.

### Transcript identity

`TranscriptRecord.speakerID` remains the stable per-meeting identity field. A
new source value distinguishes microphone, system audio, mixed fallback, and
offline room audio. Presentation converts stable identifiers such as `me`,
`remote`, `remote-1`, and `room-1` into localized labels.

Final transcript replacement is transactional from the repository's point of
view: existing records remain untouched until all replacement records are
valid, then the new revision is saved as one operation.

## User Interface

### Meeting detail order

The detail page becomes:

1. Header and meeting state
2. Local recording player or active recording card
3. Summary and archive
4. Full transcript
5. Bookmarks

### Full transcript disclosure

The transcript is displayed in a disclosure-style card titled "完整转录内容".

- A meeting without a summary starts expanded.
- When a summary is first generated, the transcript automatically collapses.
- Reopening a meeting that already has a summary starts collapsed.
- A user's manual expansion or collapse is respected for the remainder of that
  detail-view session.

Each row displays a timecode, a compact speaker badge when identity is known,
and selectable text. "我" uses one fixed accent treatment. Other speakers use a
deterministic color derived from the per-meeting speaker identifier. Unknown
offline or mixed fallback transcripts remain readable without a misleading
speaker badge.

### Experimental setting

Settings gains a separate "试验功能" card with the toggle "FluidAudio 说话人分离".
Supporting text explains that it is off by default, runs locally, may download
models the first time, and increases post-meeting processing time. The first
implementation prepares models lazily when an enabled meeting is finalized;
it does not add manual model-management controls.

The detail view may show a compact non-blocking status while speaker processing
is active and a dismissible warning if processing degraded.

## Failure Handling

Data priority is:

1. mixed master recording
2. source tracks
3. speaker labels

The following degradation rules apply:

- A source-track writer failure records a warning and allows the master track
  to continue.
- A FluidAudio model download, initialization, or inference failure falls back
  to coarse online labels ("我" and "远端") when source transcription succeeded.
  An offline meeting falls back to its unlabelled transcript.
- If any required source transcription fails, no partial final transcript is
  committed; the existing mixed provisional transcript is retained.
- Final transcript replacement is all-or-nothing to avoid duplicate text.
- Speaker enrichment failure never prevents playback, summarization, or Notion
  archiving.
- Every success and failure path leaves the meeting in a usable non-processing
  state and stores only a safe error code, not raw model or audio data.

## Testing Strategy

### Unit tests

- Capture packets preserve synchronized master, microphone, and system frames.
- Track writers use distinct names and manifests while the master keeps the
  existing naming convention.
- Settings defaults to off, persists changes, and is snapshotted at start.
- Speaker assignment selects the greatest time overlap and numbers speakers by
  first appearance.
- Transcript assembly orders tracks chronologically and preserves simultaneous
  local and remote entries.
- Repository replacement is atomic and retains the previous revision on save
  failure.
- Failure policies select coarse labels or provisional mixed transcripts as
  designed.
- Detail layout policy orders summary before transcript.
- Disclosure policy expands before a summary and collapses after one appears.
- Speaker display labels and deterministic colors are stable.

### Integration tests

- Online meeting with diarization off: master playback plus "我/远端" final
  transcript.
- Online meeting with diarization on: remote speaker timeline assignment.
- Offline meeting with the setting off and on.
- Pause, resume, stop, tail-frame flush, and source-writer degradation.
- Legacy meeting with only `manifest.json` still loads and plays.
- FluidAudio is hidden behind an adapter and replaced by deterministic fakes in
  automated tests; tests never download production models.

### Manual acceptance

The user will verify:

- A Meet call displays local microphone speech as "我" and system audio as
  remote speech.
- Multiple remote participants receive usable numbered labels when the
  experiment is enabled.
- A multi-person offline meeting receives numbered labels when enabled.
- Recording playback and existing history remain intact.
- Summary placement and transcript folding match the approved behavior.
- First-use model preparation and failure warnings are understandable.

## Non-Goals

- Cross-meeting speaker recognition or voiceprint enrollment
- Manual speaker renaming
- Real-time streaming diarization
- Reprocessing existing meetings
- Replacing WhisperKit transcription with FluidAudio ASR
- Changing the mixed master playback format
