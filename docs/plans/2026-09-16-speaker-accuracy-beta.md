# Speaker attribution accuracy Beta — 2026-09-16

## Scope and baseline

Local branch: `codex/diarization-accuracy-beta`, based on released source
`beaae3cb19a7efa2aabb559ca3ab7d6696103b1d` (1.3.2 build 27).
Candidate: Beta 1.3.3 build 28. Production configuration remains 1.3.2 (27).
The original Batch 9–16 checkout is not edited. No commit, push, installation,
release, or appcast update is authorized by this implementation batch.

User reports four and five actual speakers in the two problem meetings. That
is a participant-count reference, not word-by-word speaker ground truth. We do
not bind those counts to guessed meeting IDs or silently change stored meetings.

## Changes

- Enable Whisper word timestamps and retain them through sanitization,
  deduplication, the transcription queue, storage, and final/retry attribution.
  Models, language auto-detection, audio gain, and chunk duration are unchanged.
- Adapt timestamp token grouping for macOS Chinese language codes `zh-Hans`
  and `zh-Hant`. The pinned SDK compares only `zh` and otherwise treats Chinese
  text as space-separated. Forward ASR encode/decode unchanged; conserve every
  token and complete Unicode sequence. Do not fork/regenerate dependencies.
- Attribute measured word spans, combining union coverage per raw speaker.
  Do not double-count repeated intervals or select a nearest voice in silence.
  Preserve the original text and order. Use one speaker-ID mapping for the
  complete meeting, not new numbering for each transcript chunk.
- Preserve overlap from FluidAudio reconstruction; overlap remains excluded
  from clean embedding extraction. Existing clustering threshold is unchanged.
- Show “说话人待确认” / “重叠发言” when evidence is insufficient. Coverage 0.55,
  winner margin 0.15, overlap >= max(80 ms, 20%) are conservative attribution
  rules, not calibrated probabilities or demonstrated accuracy percentages.
- Add a native, compact “校准说话人” menu to completed/retryable meetings:
  automatic / exact actual speaker count / count range. Counts are per meeting,
  bounded to 1–20, forwarded to FluidAudio, and resettable to automatic. Model
  weights are reused while each request owns its immutable clustering config.
  An unmet count produces a warning, never invented speaker IDs.
- Protect manual edits at persistence time, including edits made during
  inference. Corrected rows keep their original anchors; a correction spanning
  voices remains one unchanged user sentence with an uncertain label. Do not
  distribute typed text over guessed timestamps or duplicate original child rows.
- Online source review reads the actual microphone/system tracks locally, holds
  at most two reader chunks, and stores only advisory observations. Energy
  dominance does not establish personal identity. High waveform correlation
  within +/-200 ms warns of possible echo; it does not delete text/audio or merge
  speaker identities. Missing tracks do not invalidate usable master results.

## Boundaries

Historical transcripts without word timestamps are not retranscribed. They can
be reclustered using the original recording and an actual count, but cannot be
honestly split inside a sentence without alignment evidence. Ambiguous spans
remain unassigned. Short interjections help only when both the diarizer and word
aligner provide usable evidence. Overlapping speech is flagged, not magically
separated into two clean audio signals.

No voiceprint library, biometric identity matching, cloud audio upload, capture
architecture change, decoder-language policy change, or UI redesign is included.
The legacy physically tagged online fallback remains available. New source
advice is separate from the persisted physical track and from speaker identity.

## Validation and acceptance

Background-only tests use `Scripts/test_in_background.sh`. No visible UI tests,
keyboard/mouse automation, app activation, or replacement of an installed app.
The two interactive panel tests remain NOT RUN. Full-suite local-audio probes
are opt-in and skipped without their external config.

Evidence covers silence gaps, ambiguous/overlapping speakers, duplicate/combined
intervals, short interjections, Chinese/English text conservation, UTF-8 token
boundaries, four/five-speaker ID consistency, count forwarding/reset, manual-edit
protection, source/echo advice, cancellation, old-store migration, and existing
editor/capture behavior. A synthetic four-hour/3,000-row fixture checks the
attribution algorithm, not four hours of real audio inference or GUI smoothness.

Real-audio probes operate read-only, keep audio/transcripts local, and emit only
counts/timings. An initial old probe config failed because one recording had
been removed and its selected opening produced no usable text. The failure log
is retained outside the repository. Re-selection uses complete current manifests.

Final test/package results are recorded below after verification. Human
speaker-identity/turn accuracy, overlap behavior, and on-device editing remain
pending manual acceptance. Returning the requested count alone is not proof of
correct diarization. Do not publish this candidate before that gate.

### Final evidence

- Final background suite: exit 0; 1,431 discovered/executed, **1,425 passed,
  6 opt-in local probes skipped, 0 failed**. The 2 interactive panel tests are
  separately excluded by the safety script, not counted as passing.
- Final focused alignment + cached-model real-audio probe: 16 passed, 0 failed.
  On the same three Chinese audio chunks the timing groups changed from
  2/1/4 whole-sentence units to 14/13/31 usable token/word units; latest decode
  times were 2.34/2.15/3.94 seconds for approximately 10/5/10 seconds of audio.
  This verifies timestamp availability, not human semantic/speaker correctness.
- Two current complete recordings: 1,247.62 s and 3,574.14 s. Label-only
  finalization with source review completed in 24.86 s and 71.76 s, with
  481/623 and 1,330/1,787 synthetic text anchors receiving source advice.
  Real audio is used but anchor text is deliberately synthetic; no private
  transcript is exported, overwritten, or included in evidence logs.
- The same recordings with a 4–5 speaker constraint completed in 12.67 s and
  45.19 s. **Both returned 5 clusters.** Given the user's reported counts of
  four and five, the range control is not proof that all identities or turns
  are correct. Per-meeting exact-count and human turn-level review remain needed.
- Synthetic 4-hour/3,000-row assignment regression passed (roughly 0.03 s in
  one focused run); no claim is made about GUI performance from this test.
- Existing optional-field migration, manual corrections/undo, recording,
  diagnostics, model catalog, document/Notion, and release-policy tests passed
  in the background unit suite. There remains an existing screenshot callback
  Sendable warning; this batch does not change that code.
- `git diff --check`: PASS. HEAD unchanged. No staged files, commit, push,
  GitHub changes, or installed-app replacement.
- Final Beta package: `MeetingNotes-1.3.3-beta-build28.dmg`, 9,861,033 bytes.
  SHA256: `e12af7bc683509cd643a6b3f9fcbaedfdffd60a576ede09a00e856f8bb78caac`.
  Beta build exit 0; `hdiutil verify`, mounted app identity, embedded Sparkle,
  code signature, sandbox/audio-input/network-client entitlements, privacy
  string, and `PACKAGE_VALIDATION` all PASS. Local self-signed identity;
  Developer ID/notarization are NOT present. The app has not been installed
  or launched for human acceptance. The earlier pre-final package was moved
  to the external temporary evidence directory, not published.
