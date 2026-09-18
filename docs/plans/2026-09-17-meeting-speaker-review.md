# Meeting-level speaker references and grouped review

Extend the uncommitted stable 1.3.4 (29) candidate without discarding it.
User approved: per-meeting references, bounded acoustic re-analysis of uncertain
spans, previewed grouped confirmation/undo, fewer repetitive labels. No implicit
publication, installation, desktop automation, audio upload or voice enrollment.

## Contracts

- Preserve the existing whole-meeting model, ASR text, measured word timestamps,
  source identity and strict original attribution thresholds.
- Retain candidate/reason evidence independently of confirmed speaker IDs.
  Candidate similarity and time coverage are not calibrated probabilities.
- Per-meeting references come from clean speech in the same full analysis, are
  temporary, anonymous, and never enter the optional cross-meeting identity store.
- Re-analyse only uncertain regions against those references. Keep all local
  speakers when testing overlap; do not discard unmatched voices and accidentally
  turn overlap into a single speaker. Only strong acoustic + temporal evidence
  may promote uncertain to attributed. Known/manual/overlapping speech is never
  overwritten. Silence is not filled from a neighbouring identity.
- Reuse cached Core ML models and the existing converted disk audio. Limit each
  window to 20 seconds, at most 12 windows/120 seconds extra inference per pass.
  Cancellation exits; optional refinement failure preserves the original result.
- Group review shows the candidate, reason, selectable excerpts, seek/playback,
  affected count and explicit confirmation. Unrelated unknowns are not one group.
  Human assignments are excluded. Validate IDs/evidence again at save time.
- Batch changes are one local transaction with one-step undo, preserving text,
  timestamps and subsequent text edits. Reject stale undo after a later speaker
  edit or transcript replacement. Keep existing keyboard text undo intact.
- Display compact candidates for related uncertain fragments without presenting
  them as confirmed. Do not merge unknown fragments belonging to different people
  or cross a measured speaker change, overlap, note or screenshot boundary.

## Validation

Deterministic coverage: candidate/reason retention, acoustic reference matching,
unmatched-speaker overlap, silent gaps, short interruptions, bounded windows,
text/timing conservation, manual protection, atomic batch/rollback/undo/staleness,
legacy migration, grouping, cancellation. Full tests use the background-only
runner. Real meeting probes remain local/read-only; uncertainty reduction is not
proof of identity accuracy without human ground truth.

Build the next stable candidate as 1.3.4 (30), leave Beta 1.3.3 (28) unchanged.
Evidence directory: `/tmp/MeetingNotes-SpeakerReview.kT42y4/`.

## Implementation and verification — 2026-09-17

- Added optional persisted candidate/reason metadata, distinct from actual
  speaker assignment. Legacy store migration leaves it nil; canonical edits,
  assembler, replacement and manual-ID remapping preserve it safely.
- Full analysis supplies anonymous meeting-only 256-dimensional references.
  Eligibility requires at least five seconds of clear, non-overlapping speech;
  duplicate intervals do not inflate that duration. Local passes reuse models
  and converted PCM, preserve unmatched voices and use automatic local count.
- Conservative uncalibrated cosine gates: candidate >=0.72 / margin >=0.08;
  strong >=0.85 / margin >=0.12. Automatic promotion additionally needs >=80%
  temporal coverage / >=50% temporal margin, no competing global evidence,
  agreement across covering windows, and no unresolved local window. Conflicting
  acoustic/time candidates stay outside bulk groups. These are engineering
  safeguards, not a measured probability of correct identity.
- Preview groups do not auto-select rows. Explicit confirmation is atomic and
  checks current IDs, source, times, status and hint. Undo is a one-step,
  in-session receipt; later speaker edits or transcript replacement invalidate
  it. Text changes are not reverted. Existing keyboard text undo is unchanged.
- Native material review sheet supports selection and bounded user-triggered
  playback (up to 12 seconds). Adjacent compatible uncertain fragments can share
  a display row, but not across overlap, edits, candidates, notes or screenshots.
- Extra analysis is bounded per pass, not guaranteed to recheck every uncertain
  word in a multi-hour recording. Unresolved/no-evidence speech remains visible.

Fresh validation:

- Initial focused run: 39 passed, 0 failed, exit 0.
- UI-policy / existing pipeline focused run: 145 passed, 0 failed, exit 0.
- Persistence / migration / pipeline / release focused run: 156 passed,
  0 failed, exit 0 (before the final extra conflicting-window regression).
- Final complete background runner: 1493 executed, 1487 passed, 6 explicit-opt-in
  real-audio probes skipped, 0 failed, exit 0. Includes 32 new review tests.
  Two interactive floating-panel tests and UI automation were NOT RUN.
- Swift 6 complete strict-concurrency compilation: PASS.
- Release packaging: exit 0, PACKAGE_VALIDATION=PASS. Mounted bundle identity,
  embedded Sparkle, codesign, sandbox and required entitlements verified by the
  packager. Separate hdiutil verification: exit 0.
- Stable identity: 会议记录 / com.shenminghao.MeetingNotes / 1.3.4 (30).
  Local self-signed certificate; NOT notarized, APPLE_DISTRIBUTABLE=NO.
- DMG: `MeetingNotes.dmg`, 10,178,604 bytes.
  SHA256: `1777ddf91594b87d83dc7dea4602c6e79e6dcdc6d5065d0db7c9b0d370ed58a6`.
- Beta 1.3.3 (28) DMG unchanged:
  `e12af7bc683509cd643a6b3f9fcbaedfdffd60a576ede09a00e856f8bb78caac`.
- Package.resolved unchanged:
  `07d9b54af514d90b9535bf5c72c8c844c4e72b989bf673a8882d567f956ed221`.
- HEAD unchanged: `0dee08f86efd0d6eff0dd2bbf0c94d5699c7a0df`.
  No staging, commit, push, publication, local installation or app launch.

Still pending: actual-app human review of representative speech, batch selection,
playback and undo. No claimed diarization accuracy improvement percentage, no
real-person voice enrollment and no user audio uploaded. To try on an older
meeting: 校准说话人 → 复核说话人 → 试听 → 勾选 → 确认所选片段.
