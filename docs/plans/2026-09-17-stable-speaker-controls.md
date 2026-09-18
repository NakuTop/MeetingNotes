# Stable speaker correction and optional local identity library

Baseline: released 1.3.3 (28), source 0dee08f. Work directly on the stable
configuration, preserving the original dirty Batch worktree and Beta channel.
Do not install or launch an app. Validation is background-only.

## Required behavior

- Every transcript turn, including uncertain/overlapping/unlabelled turns,
  allows assigning an existing speaker or creating the next speaker number.
  This changes only the selected turn, not every unknown turn. A separate
  existing action still renames a speaker throughout the meeting.
- Manual assignments persist, override live/final/retry inference, preserve
  edited text and measured word timing, and can be returned to automatic.
  Recalibration must not reuse a protected identity for an unrelated cluster.
- Retain existing whole-meeting offline FluidAudio and actual word alignment;
  no invented timings, threshold tuning or replacement ASR model is justified.
- Optional local voiceprints: disabled by default, explicit named enrollment
  from user-confirmed clean single-speaker audio, encrypted on disk using a
  device-local Keychain key. No waveform copy in the library, export, cloud
  upload, DeepSeek or Notion payload change. Delete one/all profiles in-app.
- User selected suggestions-only matching: no automatic naming. Quality,
  model compatibility, similarity and winner-margin gates must reject
  ambiguous/short/overlapping/noisy input. Scores are not probabilities.
- Reuse the production audio reader and serialized cached offline models.
  Bound audio and embedding memory; cancellation/disable/delete must prevent
  stale results from saving a profile or applying a name.

## Verification

Cover manual assignment scope/reopen/rollback/live updates/recalibration,
unknown-to-known UI policy, text/timing conservation, encryption/tamper/model
identity, explicit consent/default-off/deletion, suggestions-only and stale
completion rejection. Run focused and full background suites and stable package
validation. Human accuracy and packaged UI acceptance are reported separately.
Stable publication is a separate explicit release gate, not implicit in coding.

## Implemented behavior

- The existing transcript badge is now a native menu for all turns, including
  uncertain, overlapping and unlabelled turns. Its existing capsule styling is
  retained. Assignment is scoped to that turn; global rename remains separate.
- Human overrides and their previous automatic attribution persist in optional
  SwiftData fields. Live updates skip overrides and reserve human-created IDs.
  Final/retry attribution remaps automatic clusters, preserves protected rows,
  words, corrections and names, and fails closed if their origin is untraceable.
- The optional library is accessible from the meeting and transcript badge.
  A finished meeting's selected master-track audio is read through the production
  16 kHz reader (5–20 seconds). Explicit consent and a known single speaker are
  required for enrollment; known overlap/echo is rejected. Matching is an explicit
  action, never automatic naming. Only “确认用于本段” changes the selected turn.
- The pinned FluidAudio 0.13.2 offline extractor uses the same cached models and
  serialized inference owner as meeting diarization. It rejects multiple speakers,
  insufficient voiced duration and invalid 256-dimensional embeddings. Compatible
  normalized embeddings need cosine >= 0.80 and a winning margin >= 0.08. These are
  conservative, **uncalibrated** gates, not accuracy claims or probabilities.
- Profiles are AES-GCM encrypted with a device-local, non-synchronizing Keychain
  key. Only ciphertext is written, directory/file permissions are 0700/0600,
  the directory is excluded from backup and replacement is atomic. One/all profile
  deletion never deletes meeting audio or transcript names. Duplicate names are
  rejected rather than silently overwriting an enrolled profile.
- Cancellation, disable, deletion, rapid out-of-order toggles and stale suggestions
  are covered. No new audio/voiceprint upload or Notion/DeepSeek payload path was
  added. Confirmed names become ordinary transcript labels, as explained in UI.
- The existing whole-meeting local diarization, speaker count controls and real
  Whisper word timings are retained. No ASR, clustering threshold, recording,
  screen capture, diagnostic, Notion or DeepSeek behavior was redesigned.

## Fresh verification — stable candidate 1.3.4 (29)

- Full background suite: **1461 executed, 1455 passed, 6 opt-in probes skipped,
  0 failed, exit 0**. Includes 30 new tests covering the controls and voiceprints.
  Two interactive floating-panel tests and all UI automation were NOT RUN.
- Background Debug build-for-testing: exit 0. Release build/package: exit 0.
  Existing screenshot Sendable and AppIntents metadata warnings remain; no new
  concurrency warning in the added code.
- New persistence fields migrate from the legacy disk fixture and survive disk
  reopening; failed saves roll back labels, names and content revision. Model
  comparisons and encryption tests use local test vectors/temporary stores, not
  the user's voice or real Keychain entries.
- `git diff --check`: PASS. No stage, commit, push, appcast edit, GitHub publish,
  local installation, visible app launch or permission modification was done.
- The Xcode project changed only stable Debug/Release version/build. Beta remains
  1.3.3 (28); existing Beta DMG and pinned Package.resolved hashes are unchanged.
- Release DMG: `MeetingNotes.dmg`, **10021645 bytes**.
  SHA256: `2b92433485a451d4ce2bc3b3946e30ead15f16ca419dbd1443bee9aaf55d117e`.
  `hdiutil verify`, mounted bundle identity, codesign deep/strict, Sparkle runtime,
  sandbox/audio-input/network-client/privacy string: package validation PASS.
  Identity: 会议记录 / com.shenminghao.MeetingNotes / 1.3.4 (29).
- Same local update signing certificate, not Developer ID/notarized;
  `APPLE_DISTRIBUTABLE=NO`. Prior 1.3.3 DMG retained in the local evidence folder.

Evidence logs: `/tmp/MeetingNotes-SpeakerControls.G5Zart/` (`full-release-candidate.log`,
`package-release.log`). Intermediate checks exposed a compiler expression issue
and a new test missing the diarization opt-in precondition; both were corrected
before the clean final run above.

## Remaining manual/release gates

- Click a “说话人待确认” turn; assign an existing/new number during recording and
  after stopping. Recalibrate and reopen; verify the human label and text remain.
- With the speaker's consent, enroll a clean 5–20 second turn, match another
  turn, confirm the name, then delete/disable the library. No real voice was
  enrolled or classified by Codex. Matching accuracy and the new packaged UI
  remain HUMAN PENDING, not inferred from fake-vector tests.
- If the candidate is accepted, publication to GitHub/stable appcast needs an
  explicit release instruction. The installed production app was not replaced.
