# MeetingNotes 1.3.1 Window Screenshot and Long-Meeting Performance Implementation Plan

> **For Codex:** Execute this plan in the isolated `codex/beta-1.3.1-performance` worktree. Use test-driven development and verification-before-completion. Do not commit or push until the packaged Beta passes the user's human smoke test.

**Goal:** Add per-click native window screenshot selection, make the complete document-mode slider halves clickable, and keep editing/switching responsive for a four-hour meeting with roughly 3,000 transcript segments.

**Architecture:** Preserve the current recording, transcription, document, Notion, and visual architecture. Replace display selection with a single-window ScreenCaptureKit picker; make slider hit testing coordinate-explicit; isolate per-keystroke draft mutations from full-view invalidation and cache/incrementally refresh immutable timeline projections.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSTextView`, ScreenCaptureKit, SwiftData, XCTest, Xcode 26 SDK; macOS 15 deployment target, arm64 only.

---

## Safety and release gate

- Base SHA: `fa7f420deb5faf65b15998c085e41676d3c8d716`.
- Worktree: `.worktrees/codex/beta-1.3.1-performance`.
- Do not run xcodegen or regenerate `project.pbxproj`.
- Do not change production identity or stable appcast.
- Keep all implementation uncommitted and unpushed until human Beta acceptance.
- Do not modify audio capture, diagnostics, Whisper, FluidAudio diarization behavior, DeepSeek payloads, or Notion replacement behavior.
- Dependency exception approved after validation: pin official FluidAudio 0.13.2 exactly to restore Xcode 26.3 Release/Archive compatibility. MeetingNotes continues to use the unchanged `OfflineDiarizerManager` path; do not switch diarization engines or models.

### Task 1: Establish deterministic long-meeting performance contracts

**Files:**

- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotesTests/MeetingTimelineDisplayPolicyTests.swift`
- Modify: `MeetingNotesTests/MeetingEditAutosaverTests.swift`

**Step 1: Add passing 3,000-segment baseline fixtures**

Create a deterministic four-hour meeting fixture with 3,000 ordered transcript values. Add baseline tests proving:

- initial projection preserves count/order/grouping semantics;
- the final timestamp covers the intended four-hour range;
- mixed transcript/note/screenshot ordering remains deterministic at scale.

Keep this task as a correctness/performance fixture baseline that passes before production changes. Add the failing work-count and invalidation tests in Tasks 4 and 5 alongside the APIs they drive. Do not make wall-clock timing the only pass condition.

**Step 2: Run the focused tests and record the passing baseline**

Run:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesTests/MeetingTimelineDisplayPolicyTests \
  -only-testing:MeetingNotesTests/MeetingEditAutosaverTests
```

Expected: baseline correctness tests pass. Record elapsed performance as diagnostic evidence only; deterministic work-count regressions arrive in Tasks 4 and 5.

### Task 2: Add native single-window screenshot selection

**Files:**

- Modify: `MeetingNotes/Recording/MeetingScreenshotCapture.swift`
- Modify: `MeetingNotes/ViewModels/RecordingAnnotationViewModel.swift`
- Modify: `MeetingNotesTests/MeetingScreenshotCaptureTests.swift`
- Modify: `MeetingNotesTests/RecordingAnnotationViewModelTests.swift`

**Step 1: Write failing picker state-machine tests**

Cover:

- selection produces a capture using the returned content filter;
- every request presents a fresh single-window picker;
- cancellation returns no screenshot and no error feedback;
- only one selection may be in flight;
- task/meeting cancellation discards late picker selection;
- permission, window disappearance, capture, file, and repository failures retain existing rollback behavior;
- picker continuation resumes exactly once.

**Step 2: Write failing native-pixel policy tests**

Verify the requested output is derived from `contentRect × pointPixelScale`, rounded safely, never upsampled, and bounded by the existing maximum capture envelope. Preserve the existing Notion 4.5 MB derivative limit tests.

**Step 3: Run screenshot-focused tests and verify RED**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingScreenshotCaptureTests \
  -only-testing:MeetingNotesTests/RecordingAnnotationViewModelTests \
  -only-testing:MeetingNotesTests/NotionScreenshotDerivativeBuilderTests
```

**Step 4: Implement the smallest picker/capture state machine**

- Present `SCContentSharingPicker` with `.singleWindow` only.
- Buffer exactly one selection/cancel/error terminal result.
- Remove observers and release continuation state on every terminal path.
- Capture with the returned `SCContentFilter` using best resolution and no upscaling.
- Treat user cancellation as a neutral outcome in `RecordingAnnotationViewModel`.
- Preserve token/session guards before file or repository mutations.

**Step 5: Re-run focused tests and verify GREEN**

### Task 3: Make the full document-mode halves clickable

**Files:**

- Modify: `MeetingNotes/Views/MeetingDocumentModeSlider.swift`
- Modify: `MeetingNotesTests/MeetingDocumentModeSliderDragPolicyTests.swift`
- Modify: `MeetingNotesUITests/MeetingNotesUITests.swift` only if the existing mode-switch UI coverage lives there

**Step 1: Add failing coordinate and accessibility tests**

Test left/right centers, blank space, top/bottom edges, outer edges, exact midpoint, disabled state, and click/drag interaction.

**Step 2: Run the slider tests and verify RED**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingDocumentModeSliderDragPolicyTests
```

**Step 3: Implement full-half hit testing**

- Give both labels/buttons a full rectangular content shape.
- Route coordinate taps by half through a deterministic policy.
- Preserve two accessible buttons and all existing visual/drag behavior.
- Expand only the invisible hit area; do not alter the visible 40-point capsule.

**Step 4: Re-run focused tests and verify GREEN**

### Task 4: Make transcript drafts O(1) and stop per-key full-view invalidation

**Files:**

- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/Editing/MeetingEditAutosaver.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Modify: `MeetingNotesTests/MeetingEditAutosaverTests.swift`

**Step 1: Add failing edit-isolation tests**

Assert that:

- a stable draft identity maps directly to one pending draft;
- continued typing changes the draft value/token but not the draft-boundary revision;
- first dirty edit and final clear each change the boundary revision once;
- unchanged `.idle` save state is not re-published on every key;
- flush, retry, exact replacement, grouped-turn preservation, and save failure retain current semantics.

**Step 2: Run focused tests and verify RED**

**Step 3: Implement indexed, observation-isolated draft storage**

- Maintain stable O(1) indexes for transcript and note drafts while preserving deterministic snapshot order for existing APIs/tests.
- Exclude character-only internal draft storage from broad Observation invalidation.
- Publish a narrow boundary revision only when the set of draft targets changes.
- Keep every keystroke in the latest in-memory draft and continue resetting the 350 ms autosave.
- Avoid assigning the same autosave state repeatedly.

**Step 4: Re-run focused tests and verify GREEN**

### Task 5: Cache and incrementally refresh the timeline projection

**Files:**

- Modify: `MeetingNotes/Views/MeetingTimelineDisplayPolicy.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/MeetingDetailView.swift`
- Modify: `MeetingNotesTests/MeetingTimelineDisplayPolicyTests.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Add failing cache/incremental tests**

Cover:

- identical structural keys reuse the projection;
- character-only draft updates reuse the projection;
- first draft boundary, note, screenshot, bookmark, correction, or speaker change invalidates it;
- safe append-only transcript input updates only the tail;
- out-of-order append or destructive change falls back to full rebuild;
- incremental and full results are exactly equal;
- late asynchronous projection generation cannot replace a newer snapshot.

**Step 2: Run focused tests and verify RED**

**Step 3: Implement an immutable projection snapshot**

Calculate visible turns, timeline items, and speaker options once per structural snapshot. Pass the ready snapshot into `TranscriptView`; do not recompute `visibleTurns` separately for the timeline and speaker selector.

Use a conservative append-only fast path. If any invariant is uncertain, fall back to the existing full policy to protect correctness.

**Step 4: Make recording refresh version-aware**

Before rebuilding, compare a lightweight meeting structural signature. Skip unchanged 400 ms polls. Keep cancellation and active-meeting checks.

**Step 5: Re-run focused and 3,000-segment tests and verify GREEN**

### Task 6: Cache native text layout without changing appearance

**Files:**

- Modify: `MeetingNotes/Views/InlineEditableMeetingText.swift`
- Modify: `MeetingNotesTests/MeetingDetailViewModelTests.swift`

**Step 1: Add failing layout-cache tests**

Verify unchanged text/width/font/line limit reuses the measured result, while text or width changes invalidate it. Preserve all existing sizing, wrapping, context-menu, selection, undo, newline, and flush tests.

**Step 2: Run focused tests and verify RED**

**Step 3: Implement per-editor measurement caching**

Cache only value-type measurement inputs/results owned by the native view. Never cache stale binding or SwiftData objects. Invalidate on text, width, font, alignment, or line-limit changes.

**Step 4: Re-run focused tests and verify GREEN**

### Task 7: Run performance evidence and regression validation

**Files:**

- Modify tests only if a deterministic defect is found

**Step 1: Run static checks**

```bash
git diff --check
```

Search changed production files for accidental debug output and unsafe continuations.

**Step 2: Run focused functional/performance suites**

At minimum:

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test \
  -only-testing:MeetingNotesTests/MeetingScreenshotCaptureTests \
  -only-testing:MeetingNotesTests/RecordingAnnotationViewModelTests \
  -only-testing:MeetingNotesTests/MeetingDocumentModeSliderDragPolicyTests \
  -only-testing:MeetingNotesTests/MeetingDetailViewModelTests \
  -only-testing:MeetingNotesTests/MeetingTimelineDisplayPolicyTests \
  -only-testing:MeetingNotesTests/MeetingEditAutosaverTests \
  -only-testing:MeetingNotesTests/NotionScreenshotDerivativeBuilderTests
```

**Step 3: Run Debug build, all units, and whole scheme**

```bash
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Debug -destination 'platform=macOS' build
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test -only-testing:MeetingNotesTests
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=macOS' test
```

**Step 4: Profile the 3,000-segment fixture in an optimized build**

Record:

- projection/full-rebuild counts;
- p95 main-thread character handling target `< 16 ms`;
- summary/detailed switch target `< 100 ms`;
- memory before/after sustained editing;
- scroll/expand behavior.

Treat automated counters as deterministic evidence and packaged-app observation as the final perceptual gate.

### Task 8: Prepare Beta 1.3.1 (19) without publishing

**Files:**

- Modify: `project.yml`
- Modify manually: `MeetingNotes.xcodeproj/project.pbxproj`
- Modify: `Scripts/build_and_package.sh`

**Step 1: Add failing identity assertions if current tests do not cover Beta 19**

Verify production remains `会议记录 / com.shenminghao.MeetingNotes / 1.3.0 (18)` and Beta becomes `会议记录 Beta / com.shenminghao.MeetingNotes.beta / 1.3.1 (19)`.

**Step 2: Update only the required Beta version/build references**

Do not run xcodegen. Manually audit the pbxproj diff and package dependencies.

**Step 3: Build and verify the DMG**

```bash
./Scripts/build_and_package.sh Beta
hdiutil verify MeetingNotes-1.3.1-beta-build19.dmg
shasum -a 256 MeetingNotes-1.3.1-beta-build19.dmg
```

Verify mounted identity, privacy string, code signature, sandbox, audio-input, network client, Sparkle embedding, and package validation.

**Step 4: Human Beta gate**

Ask the user to test the actual packaged app:

- choose and capture several windows;
- inspect local and Notion image clarity/size;
- click every area of both slider halves;
- edit, scroll, expand, and switch documents in the 3,000-segment fixture;
- confirm autosave and Notion replacement still work.

Stop before commit, push, appcast, tag, or GitHub Release. Continue those only after explicit human approval.
