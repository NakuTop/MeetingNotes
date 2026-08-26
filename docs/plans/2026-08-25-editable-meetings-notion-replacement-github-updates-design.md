# Editable Meetings, Notion Replacement, and GitHub Updates Design

**Status:** Approved on 2026-08-25

## Context

The current Beta combines the accepted production meeting experience with the
validated audio-device and smart-diagnostic updates. The next phase should make
meeting content correctable without changing the accepted recording,
transcription-model, or diagnostic behavior, and should establish a secure
in-app update path so later releases do not require repeated manual DMG
installation.

Users must be able to correct live transcript text, key summaries, detailed
minutes, speaker names, and action-item owners. Local changes save automatically,
but Notion remains an explicit user-triggered synchronization destination. A
Notion sync replaces the app-managed child page instead of continually appending
another copy.

## Goals

- Add secure in-app updates backed by GitHub Releases and Sparkle 2.
- Keep stable and Beta update channels separate.
- Let users edit transcript text in the main meeting-detail window while a
  meeting is still being transcribed.
- Let users edit structured key summaries and detailed minutes.
- Preserve manual transcript corrections through final transcription,
  segmentation, merging, and diarization updates.
- Support exact, meeting-scoped replacement across transcript content, speaker
  names, owner names, key summaries, and detailed minutes.
- Save local edits automatically without a Save button.
- Synchronize to Notion only when the user clicks **Sync to Notion**.
- Replace the complete app-managed Notion child-page body with the latest local
  canonical content, with resumable recovery from partial synchronization.

## Non-goals

- Do not change microphone capture, adaptive recovery, audio diagnostics,
  timeout budgets, PCM policy, transcription chunk duration, Whisper decoding,
  model identities, or transcript generation semantics.
- Do not improve FluidAudio diarization in this phase.
- Do not add timeline notes or computer screenshots in this phase.
- Do not add cross-meeting replacement dictionaries, fuzzy correction, edit
  history, undo across launches, or collaborative conflict resolution.
- Do not make ordinary Git pushes visible as application updates.
- Do not automatically synchronize local edits to Notion.

## Alternatives Considered

### Selected: durable correction overlay and canonical meeting content

Store generated transcript text separately from durable manual corrections,
derive one canonical meeting document for every consumer, and integrate Sparkle
as an isolated update service. This adds enough structure to preserve edits
across automatic transcript replacement without turning the meeting repository
into a general event store.

### Rejected: mutate existing generated records directly

Adding only an `isManuallyEdited` flag to transient transcript records would be
smaller initially, but final transcription may change identifiers and segment
boundaries. Manual text could then be lost or attached to the wrong segment, and
meeting-wide correction would become difficult to apply consistently.

### Rejected: full immutable event log

Recording every generated revision and user operation would provide complete
history and rollback, but it requires a broad persistence redesign and migration
that is unnecessary for the requested behavior.

## Architecture

The phase introduces four bounded components while leaving capture and model
services unchanged.

### Update coordinator

`UpdateCoordinator` adapts Sparkle state to application state and settings. It
owns update checking and presentation but does not own meeting lifecycle state.
An application-level activity gate tells it when installation is permitted.

### Transcript correction store

`TranscriptCorrectionStore` persists meeting-scoped manual corrections. A
correction is associated with a durable utterance anchor derived from meeting
identity, audio source, time range, and sequence context rather than relying
only on a transient transcript identifier.

The canonical text for an utterance is:

1. matching manual correction, when present;
2. otherwise the latest generated text.

Final transcription and diarization may revise timing, source attribution, and
speaker association. Reconciliation must reattach a compatible manual
correction before publishing the replacement records. Automatic work never
overwrites the correction text.

### Editable meeting document store

`EditableMeetingDocumentStore` coordinates editable structured summaries,
detailed minutes, correction revisions, local save status, and the Notion dirty
revision. Existing repository types remain the persisted source of truth; the
store provides edit and reconciliation behavior instead of creating a second
unrelated meeting database.

### Notion page reconciler

`NotionPageReconciler` creates a canonical Notion snapshot and replaces the
entire body of the MeetingNotes-created child page. It persists a synchronization
checkpoint so retries continue an incomplete replacement instead of appending a
new duplicate.

## Canonical Content Flow

The content path is:

`generated transcript -> manual correction overlay -> meeting-wide exact replacements -> structured summary/minutes -> local persistence -> explicit Notion sync`

The UI, summarization inputs, archive rendering, persistence reads, and Notion
serialization consume canonical corrected text. No downstream consumer should
silently bypass the correction layer and read stale generated text.

## Transcript Editing and Reconciliation

- Transcript text is editable only in the main meeting-detail window.
- The floating meeting panel remains limited to meeting status and controls.
- Input updates view state immediately.
- Disk writes are coalesced over a short interval to avoid one database write
  per keystroke.
- Losing focus, switching meetings, closing the window, and application
  lifecycle termination request an immediate flush.
- A failed write leaves the edited view state intact, reports that the content
  is not safely saved, and offers a retry. Failure is never represented as a
  successful save.
- Generated text remains available internally for reconciliation and debugging,
  but is not exposed as the canonical document after a manual correction.

Reconciliation must be deterministic. Exact identifier matches are preferred.
When final processing changes identifiers, the implementation uses the same
meeting and source plus compatible sequence/time overlap to reattach the manual
correction. Ambiguous matches must not apply one correction to multiple unrelated
segments; they retain the correction for explicit resolution rather than
silently corrupting text.

## Structured Summary and Minutes Editing

Key summaries and detailed minutes remain structured records. Their existing
sections and fields become editable in place rather than being flattened into a
single free-form text blob.

### Original-interface preservation amendment (2026-08-26)

Editing must preserve the existing MeetingNotes detail interface instead of
introducing a separate edit mode, replacement document layout, or editor page.

- Existing cards, material backgrounds, typography, spacing, disclosure
  sections, mode slider, row order, and information hierarchy remain visually
  unchanged.
- Existing read-only text is replaced in place by transparent, borderless
  native macOS text controls using the same font, alignment, wrapping, and
  foreground style. The field is always directly editable; there is no Edit
  button, Save button, or read-only-to-editing layout transition.
- Focus feedback uses only the subtle native accent/focus treatment. Editing
  must not add boxed form styling, heavy outlines, opaque panels, or a second
  visual language.
- Transcript timecodes, speaker badges, highlighting, row padding, and the
  floating meeting panel remain unchanged. Only the transcript text itself
  becomes editable.
- Summary and detailed-minutes sections keep their original rendering and list
  order. Existing items can be edited, but Task 6 adds no persistent plus/minus
  controls and does not turn the document into a generic rich-text form.
- Local save state reuses the existing lightweight status/error presentation.
  It must not add a permanent toolbar or large status panel. Save failure may
  reveal a native retry action because the draft is not safely stored.
- The current-meeting replacement command is exposed through a native context
  menu on editable text. Its preview/confirmation uses a compact system sheet
  with the same translucent material treatment; no replacement button is added
  to the normal detail layout.
- Regeneration continues to use the existing generate/regenerate control. A
  destructive native confirmation appears only when that action would replace
  manually edited content.

The visual target is the original translucent native macOS interface with
direct editing added as a capability, not a redesigned editor product.

The first user edit marks the affected document as manually edited and advances
its local revision. Ordinary finalization, refresh, or background generation
must not replace a manually edited document. An explicit **Regenerate** action
shows a destructive confirmation explaining that the current manual version
will be replaced. Only confirmation permits the new generated result to become
canonical.

## Meeting-scoped Exact Replacement

The replacement command applies only to the currently open meeting. It performs
literal exact-text matching; it does not use fuzzy matching or infer variants.
Supported targets are:

- canonical transcript text;
- speaker display names;
- action-item owner names;
- key-summary fields;
- detailed-minutes fields.

Before applying, the UI shows the old value, replacement value, total match
count, and affected content areas. Confirmation applies the changes as one
logical operation, advances the local revision, schedules persistence, and
marks Notion as out of date. Cancellation has no effect. Other meetings are
never scanned or modified.

## Local Save and Synchronization State

The main meeting detail presents distinct local and remote states:

- `Saving...`
- `Saved locally`
- `Save failed; changes are not safely stored`
- `Unsynced Notion changes`
- `Syncing`
- `Synced`
- `Sync failed; retry available`

A successful local save does not imply a successful Notion sync. The Notion
dirty marker compares the latest local content revision with the last fully
synchronized revision.

## Notion Replacement Protocol

The MeetingNotes-created child page is fully app-managed. Direct manual edits to
that Notion page may be removed on the next sync; the UI explains this on first
sync and when relinking a page.

Synchronization uses the following phases:

1. Freeze a canonical local snapshot and its revision.
2. Fetch every existing top-level child block, following Notion pagination.
3. Append the complete replacement body while recording newly created block
   identifiers in a durable checkpoint.
4. Only after the replacement body is complete, archive every block captured in
   the old-block snapshot.
5. Mark the snapshot revision synchronized only after cleanup succeeds.

Failure behavior:

- Failure before replacement writing leaves the old page untouched.
- Partial replacement writing leaves the old page available; partial new blocks
  are cleaned up on retry or by best-effort rollback.
- Interruption after replacement completion retains the cleanup checkpoint. A
  retry archives the recorded old blocks without appending another replacement.
- Local edits made while synchronization runs advance the local revision. The
  completed snapshot may be marked synchronized, but the meeting remains dirty
  because a newer local revision exists.
- Permission, rate-limit, and network errors do not alter local content and are
  surfaced with a retry action.

Notion has no atomic whole-page replacement operation, so temporary duplication
may be observable during an interrupted cleanup. The checkpoint protocol makes
that state recoverable and prevents indefinite stacking.

## GitHub and Sparkle Update Design

Sparkle 2 provides the application update client. GitHub Releases hosts signed
release artifacts; stable and Beta use independent appcast feeds.

- Production consumes stable releases only.
- Beta consumes prereleases from the Beta feed.
- A normal source push never changes either feed.
- Production and Beta keep separate bundle identities and never overwrite one
  another or silently switch channels.

The application checks automatically on the configured schedule and exposes a
manual **Check for Updates** action under **Settings -> About and Updates**.
When an update exists, it displays version, release notes, and download size.
The user must click **Update and Restart** before download and installation.

Installation is unavailable while any of these activities are active:

- meeting recording;
- transcription finalization;
- Notion synchronization.

The UI names the blocking activity. Returning to idle re-enables the action but
does not restart the application automatically. Failure preserves the currently
working application and presents the GitHub Release page as a manual fallback.

## Update Security and Release Pipeline

- Every update archive carries a Sparkle EdDSA signature.
- The public EdDSA key is bundled in the application.
- The private key is stored outside the repository, in local Keychain or an
  appropriately protected release secret.
- Distributed applications use Apple Developer ID signing and notarization.
- The release workflow verifies version/build, bundle identity, code signature,
  notarization result, SHA-256 digest, and Sparkle signature before publishing
  the appcast.
- Stable appcasts exclude prereleases; Beta appcasts cannot be consumed by the
  production bundle.

The current development environment has no usable Developer ID identity. The
module can be implemented and tested locally, but distribution is not release
ready until signing and notarization credentials are configured and verified.

The currently installed application has no Sparkle updater. Users must manually
install the first updater-enabled release once. Subsequent releases can use the
in-app path.

## User Interface

- Clicking transcript text enters inline editing; ending focus ends editing but
  does not require a Save button.
- Existing speaker and owner editing entry points gain the meeting-wide exact
  replacement command.
- Summary and minutes fields become directly editable inside their current
  structured sections.
- The replacement sheet previews value, match count, and target areas.
- Local-save state and Notion-sync state remain visually distinct.
- **Settings -> About and Updates** shows current version/channel, automatic
  checking preference, manual check, available-update action, and any active
  installation blocker.

## Compatibility and Migration

- Existing meetings decode without manual-correction metadata and continue to
  display their original text.
- Migration is additive, repeatable, and must not modify audio files, meeting
  identities, timelines, model caches, or existing generated content.
- Older meetings can be edited, corrected, and synchronized using the new path.
- Capture, diagnostics, Whisper models, decoding, merging, and current production
  feature behavior remain unchanged.

## Error Handling

- Persistence failure never discards unsaved view state or reports success.
- Ambiguous transcript reconciliation never guesses across unrelated segments.
- Replacement either updates all selected in-memory targets as one logical
  operation or none; persistence failure keeps a recoverable dirty state.
- Notion replacement checkpoints survive retry and prevent duplicate appends.
- Update failures preserve the installed application.
- Update installation is fail-closed while protected activities are active.
- Unsupported signing/notarization state is reported as a release blocker, not
  a successful cross-machine update result.

## Test Strategy

### Transcript and document tests

- Manual text survives live append, final transcript replacement, resegmentation,
  diarization, repository reload, and application restart.
- Timing and speaker association may update without changing manual text.
- Ambiguous reconciliation does not duplicate or misapply a correction.
- Coalesced saving, focus flush, lifecycle flush, failure state, and retry are
  deterministic.
- Summary and minutes manual locks resist ordinary regeneration; explicit
  confirmed regeneration replaces them.
- Exact replacement changes only the current meeting and only literal matches
  across every supported field.

### Notion tests

- Existing blocks are read across all pagination pages.
- New content is complete before old content is archived.
- Failures in each phase preserve a recoverable checkpoint.
- Retry after replacement completion performs cleanup without another append.
- Edits during synchronization leave a newer local revision dirty.
- Permission, rate-limit, and network failures preserve local content.

### Update tests

- Stable and Beta feeds are isolated.
- Update presentation exposes the correct version and release information.
- Recording, finalization, and Notion synchronization block installation.
- Returning to idle permits a user-initiated update without automatic restart.
- Invalid Sparkle signatures are rejected.
- A signed older build can update to a signed newer test build without losing
  meetings or settings.

### Regression and packaged-app validation

- Run all focused persistence, transcript, summary, Notion, settings, update,
  audio, diagnostic, and meeting-lifecycle suites.
- Run the full unit suite and whole scheme with exact result reporting.
- Validate the first updater-enabled Beta by manual installation.
- Publish a higher GitHub prerelease and verify discovery, guarded installation,
  restart, and data preservation.
- Verify Developer ID signing, notarization, Sparkle EdDSA, model download, and
  application launch on another clean Mac.
- Verify the production build cannot see the Beta prerelease.

## Delivery Sequence

1. Add persistence and canonical correction behavior with migration tests.
2. Add transcript, summary, minutes, replacement, and save-state UI.
3. Replace Notion append behavior with the checkpointed whole-page protocol.
4. Integrate Sparkle and activity gating.
5. Add release automation and signed update metadata without publishing until
   Developer ID/notarization prerequisites are available.
6. Complete automated validation and packaged-app manual update testing.

FluidAudio diarization improvements and timeline notes/screenshots start only
after this phase passes its independent Beta acceptance.

## Acceptance Criteria

- Manual content is never overwritten by automatic transcript or document work.
- Every supported exact replacement remains scoped to the current meeting.
- Local edits persist automatically and visibly report failures.
- Notion changes only on explicit sync and converges to one canonical page body
  after retries.
- Stable users never receive a Beta prerelease.
- Installation cannot interrupt recording, finalization, or Notion sync.
- The first updater-enabled release documents its one-time manual installation.
- Cross-machine in-app updating is not declared ready until Developer ID,
  notarization, EdDSA, and clean-Mac testing all pass.
- Existing accepted audio and production functionality remains unchanged.
