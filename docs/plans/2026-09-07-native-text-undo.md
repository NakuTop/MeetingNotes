# Native text undo synchronization Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep native undo/redo restorations in the displayed text, binding, and local autosave data.

**Architecture:** Preserve the existing AppKit undo stack and text editor. Reconcile text after the editor's actual undo manager completes an undo or redo, with window/manager lifetime guards. Use real native text controls and real bindings in background tests, without desktop events or visible windows.

**Tech Stack:** Swift 6, AppKit, SwiftUI NSViewRepresentable, XCTest, existing background-only test runner.

---

## Safety

Work only in `codex/beta-1.3.1-performance` at base
`fa7f420deb5faf65b15998c085e41676d3c8d716`. Preserve all existing changes.
Do not regenerate the project, commit, push, publish, install, or launch an app.
User safety instructions override the generic plan skill's commit steps.

### Task 1: Reproduce native undo loss in a regression test

**Files:**
- Create: `MeetingNotesTests/InlineMeetingTextUndoTests.swift`

1. Host the real `InlineEditableMeetingText` in an unshown NSWindow; assert it
   remains invisible/non-key. Find its native child without accessibility APIs.
2. Change synthetic Chinese text via the text control API, break typing
   coalescing, and send the real native `undo:` action. Assert native text and
   the binding both return to the original string.
3. Change presentation to force representable refresh; assert the restoration
   survives. Repeat for full deletion and redo. Do not post artificial keyboard
   or mouse events and do not inject success callbacks.
4. Run the suite and retain the failing output before changing production:

```sh
MEETINGNOTES_BACKGROUND_DERIVED_DATA=/tmp/MeetingNotes-BackgroundTests.audio22 \
MEETINGNOTES_BACKGROUND_PACKAGE_CACHE="<existing Xcode DerivedData>/SourcePackages" \
nice -n 10 bash Scripts/test_in_background.sh \
-only-testing:MeetingNotesTests/InlineMeetingTextUndoTests
```

Expected RED: native text restored, binding still deleted, refresh loses undo.

### Task 2: Repair the existing native synchronization boundary

**Files:**
- Modify: `MeetingNotes/Views/InlineEditableMeetingText.swift`
- Modify: `MeetingNotes/ViewModels/MeetingDetailViewModel.swift`
- Modify: `MeetingNotes/Views/TranscriptView.swift`
- Test: `MeetingNotesTests/InlineMeetingTextUndoTests.swift`
- Test: `MeetingNotesTests/MeetingDetailViewModelTests.swift`
- Test: `MeetingNotesTests/MeetingTimelineDisplayPolicyTests.swift`

1. Register selector observers for `Notification.Name.NSUndoManagerDidUndoChange`
   and `.NSUndoManagerDidRedoChange` against the current native manager.
2. At a completed native operation, verify notification manager identity and
   reconcile `string` through `onStringChange`, then invalidate intrinsic size.
   Do not replay text edits into the native undo stack.
3. Track changes to the owning window/manager and detach old registrations.
   Avoid a global observer, asynchronous reconciliation, retained callback cycle,
   and per-keystroke whole-meeting snapshots.
4. Rerun Task 1 to GREEN. Add direct manager undo/redo, local autosave, multiple
   editors, manager replacement/detachment, and lifetime regression coverage.
5. Preserve the existing Chinese composition, presentation, and measurement
   cache tests. Keep any new edit to this module justified by a failing test.
6. Use will/did undo snapshots to prevent unrelated editors sharing a manager
   from publishing stale bindings. Preserve an emptied manual row's native
   editor after autosave. Treat restoration through an old target as a new edit
   when the persisted baseline changed; prefer stable correction ID after
   finalization rebinds transcript IDs. Require RED/GREEN integration coverage.

### Task 3: Verification and local handoff

1. Focused background suites: `InlineMeetingTextUndoTests`,
   `InlineMeetingTextPerformanceTests`, `MeetingEditAutosaverTests`,
   `MeetingDetailViewModelTests`, `MeetingTimelineDisplayPolicyTests`, and
   `BackgroundTestSafetyTests`.
2. Run the same background runner without filters for all permitted units.
   Its two interactive floating-panel tests and UI tests remain NOT RUN.
3. Run an ordinary build:

```sh
nice -n 10 xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes \
-configuration Debug -destination 'platform=macOS' \
-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

4. Independently review the narrow patch and resolve material issues before
   claiming completion. Verify `git diff --check`, branch/HEAD, and preserved
   audio/screenshot/package hashes.
5. If delivering a DMG, change only the Beta build 24 -> 25 references in
   `project.yml`, `MeetingNotes.xcodeproj/project.pbxproj`,
   `Scripts/build_and_package.sh`, and its release-policy test. Retain production
   1.3.0 (18). Package Beta, verify DMG hash, read-only mounted identity,
   entitlements, and deep-strict codesign. Do not install or launch it.
6. Report actual counts and pending manual Command-Z/Shift-Command-Z acceptance.

## Progress

- Design approved; preflight clean of whitespace errors; prior work preserved.
- The four original regression tests reproduced native text/binding divergence
  before the fix (7 assertions failed). Core bridge then passed 10 selected
  tests, including existing performance and background safety checks.
- Independent review identified the empty-row, old saved-target, and shared
  manager boundaries. Their RED tests failed; the 7-test integration rerun passed.
- Stable correction identity across finalization was additionally reproduced
  RED and then passed after the baseline lookup used correction ID.
- An immediate-deallocation test assumption also failed for an unmodified
  NSTextView control. A local, inactive, invisible AppKit probe showed eventual
  deallocation; lifetime coverage now waits on that condition with a 2 s bound.
- Final focused: 150 passed, 0 failed, exit 0. Full permitted background units:
  1385 passed, 0 failed, exit 0 (12 more tests than the 1373-test baseline).
- Ordinary Debug build: exit 0. Final independent review: PASS, no remaining
  material finding. Whitespace check and audio/screenshot/dependency preservation
  hashes match the turn's baseline. Beta metadata alone advances 24 -> 25;
  production remains 1.3.0 (18).
- The unchanged screenshot source still emits its prior completion/Sendable
  warning; AppIntents metadata extraction is skipped. No unrelated warning fix
  is included in this undo change.
- UI automation and the runner's two interactive floating-panel tests are NOT
  RUN. Beta 25 package command: exit 0, PACKAGE_VALIDATION=PASS. Independent DMG
  checksum verification: PASS. Local self-signed, not Apple-notarized.
- Artifact: `MeetingNotes-1.3.1-beta-build25.dmg`, 9,744,840 bytes.
  SHA256: `03e4a650c5b24549bd89b5975384f8b3990a92341d83f242a216442cbd33485d`.
  Beta 24 retained with its original SHA256:
  `33972f797c5ac7d2f220a71c8c7bdda78064779b4cae47c440882f69642ceec2`.
- Independent read-only mount: 会议记录 Beta / com.shenminghao.MeetingNotes.beta /
  1.3.1 (25), expected microphone privacy string, sandbox/audio-input/network
  client true, no get-task-allow. Deep-strict codesign PASS, stable local
  certificate requirement retained. DMG was detached without launching the app.
- No manual acceptance, installation, commit, push, or publication is claimed.
  User check: in Beta 25 delete part/all of an editable transcript, allow local
  autosave, use Command-Z, then Shift-Command-Z; confirm the restored/deleted
  state survives a refresh and new transcription remains untouched.
