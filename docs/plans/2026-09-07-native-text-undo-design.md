# Native inline text undo — approved narrow design

User approved this design on 2026-09-07 after confirming that Command-Z,
not only Control-Z, fails to retain restored text.

## Evidence

A background probe compiled the exact current `InlineEditableMeetingText.swift`
and used an unshown, non-key window with an inactive/prohibited application.
Partial deletion and deletion of the complete editor contents both registered
native undo. Sending the native `undo:` action restored `NSTextView.string`,
but did not update the SwiftUI binding. An ordinary representable refresh then
overwrote the restoration with the still-deleted binding value. Keeping the
editor as that unshown window's first responder and draining the run loop did
not change the result. No desktop input, private meeting data, or visible app
was used.

## Accepted behavior

- Keep native Command-Z undo and Shift-Command-Z redo, with native grouping.
- Propagate a completed native undo/redo through the same binding and local
  autosave path as ordinary typing, before a later view refresh can overwrite it.
- Keep the original transparent, inline UI; no Save button or history screen.
- Do not undo newly arriving transcription or another field through stale
  callbacks. Do not trigger Notion synchronization.
- This is current editor undo, not persistent cross-restart revision history.

## Scope and implementation boundary

Use the native undo manager's completed-undo/completed-redo notifications to
reconcile the editor's text with its existing binding callback. Register against
the actual manager used by the native editor, update that registration when the
editor moves to a different window, and remove stale registrations. Retain
neither obsolete windows nor editors through block observers. Do not create a
parallel whole-meeting history or intercept global keyboard events.

Production changes remain inside the inline edit/autosave/display path:

- The shared editor snapshots text only around native undo/redo and publishes
  only if that editor actually changed; other editors share the window manager.
- `MeetingDetailViewModel` compares a restored old binding with the currently
  saved text before dropping a draft. A saved correction's stable ID survives
  finalization replacing its source transcript IDs. This lookup is only needed
  when restoring the old target's original text, not on each ordinary keystroke.
- `TranscriptDisplayPolicy` retains an empty manually edited timeline row so a
  complete deletion followed by autosave does not remove its editor/undo target.
  Empty generated transcript rows remain hidden.

The two adjacent fixes were required by reproducible integration failures in
the real repository/VM/TranscriptView path, not a new history architecture.
Tests use native actions, representable refresh, local autosave, and unrelated
field/session isolation. Preserve the accepted audio and screenshot changes,
model catalog, dependencies, permissions, and all accumulated work.

## Delivery gates

Use `Scripts/test_in_background.sh`; never run UI automation or activate an app.
Run focused tests, full permitted background units, and an ordinary Debug build.
No commit, push, PR update, installation, or launch is authorized. A locally
packaged candidate, if produced, must use a new Beta build number and retain the
previous accepted DMG. Packaged-app shortcut acceptance remains the user's check.
