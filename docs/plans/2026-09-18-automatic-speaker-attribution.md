# Automatic speaker labels and continuous turns

## Scope

User request: remove pending-confirmation speaker labels, assign every utterance
a best-effort speaker, merge consecutive utterances by the same person, and
reduce long-meeting editing overhead. This builds on the existing uncommitted
1.3.4 candidate; no earlier work is discarded or published.

## Behavior

- Acoustic evidence remains the first choice. Weak coverage/ties use the most
  likely acoustic candidate; missing speech evidence uses the nearest interval
  from the same track. With no evidence at all, use one temporary numbered
  speaker, not a new person for every sentence. Live and final passes recalibrate
  automatic labels. Manual assignments always take precedence.
- Every visible sentence gets a label, including legacy unassigned rows. Reading
  an old meeting does not rewrite its source records. Internal `inferred` and
  `overlapping` status is retained; an automatic label is not a verified identity
  or a measured confidence probability. The label menu still permits correction.
- Same-speaker adjacent text merges for display across pauses/confidence changes.
  Different tracks, speakers, bookmark states, notes/screenshots, saved text
  corrections and active edit scopes remain separate. Raw rows, text, IDs and
  timestamps are never destructively merged. Correction boundaries deliberately
  stay stable so native undo and autosave keep addressing the original text.
- Source/track separation and acoustic confidence thresholds are not relaxed.
  No cloud audio calls, new models, decoder changes or recording changes.

## Performance

- Reuse one speaker interval index for each live batch and late transcript
  lookup; nearest-evidence lookup uses binary search.
- Cache canonical transcript projection by meeting/content revision and row
  counts. Draft-boundary/status changes no longer decode/sort all rows again.
  Saved edits and model label updates invalidate the cache normally.
- Correction-free transcripts avoid the second sort and correction indexes.

## Fresh background verification

`Scripts/test_in_background.sh` on the final source: exit 0.

- 1,515 executed: 1,509 passed, 6 opt-in real-audio probes skipped, 0 failed.
- Two interactive floating-panel tests and UI automation were deliberately not
  run. No visible application was launched or installed.
- 4-hour / 3,000-row synthetic meeting, 200 view-model input changes: 16.1 ms.
- 3,000-row single-speaker merged turn, 200 changes: 18.0 ms; autosave and undo
  restore exact text with all 3,000 source rows retained.
- 30,000 indexed speaker lookups over 3,000 intervals: 41.8 ms.
- These are local Debug microbenchmarks, not rendered-frame-rate measurements or
  real speaker-accuracy evaluation. Multi-person accuracy still needs human
  listening against a real recording; no private meeting audio was used here.

Regression coverage includes gap/tie/overlap attribution, manual-scope isolation,
model/human ID collisions, legacy renaming, failed-save cache/revision rollback,
timeline annotation boundaries, native undo/redo, final calibration and edit
preservation. Existing expectations that required nil labels or splitting a
same-speaker pause were updated to the new explicit product contract; confidence
and manual-edit safety assertions remain.

## Candidate

Stable configuration: 1.3.4 (32). Beta remains 1.3.3 (28).
Release build/package exit 0; mounted identity, local signature, sandbox/audio/
network entitlements, microphone privacy string and embedded Sparkle validation
passed. `hdiutil verify` passed.

- Artifact: `MeetingNotes-1.3.4-build32.dmg`
- Bytes: 10,074,695
- SHA256: `007e2180342fbeeb755cb0f044c573651379cc23ac321f7f81349647d655c6b1`
- Local self-signed, not Developer ID notarized (`APPLE_DISTRIBUTABLE=NO`).
- Previous build 31 DMG preserved in the pre-edit temporary backup.

No commit, push, appcast update, release publication or installed-app replacement.
