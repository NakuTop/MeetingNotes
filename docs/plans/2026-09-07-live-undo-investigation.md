# Live recording undo — investigation, not a claimed fix

User feedback after Beta 25: undo/redo works after recording stops, but not
while recording. The installed Applications Beta reports build 25.

## Scope

Preserve the approved native Command-Z / Shift-Command-Z editing design,
background-only testing policy, all existing work and the Beta 25 artifact.
No production source, model, audio, screenshot, release metadata or DMG changes.
No app installation/launch, desktop input, private meeting data, Git publication
or permission changes. The diagnostic tests use only in-memory synthetic text
and unshown non-key windows in the prohibited-activation test host.

## Source trace

- `MeetingCoordinator` appends real-time drafts through
  `MeetingRepositoryLifecycleAdapter.appendTranscript`; speaker IDs are absent
  at this stage. Transcript replacement/finalization is a separate later path.
- `MeetingDetailView` runs `MeetingDetailViewModel.refreshWhileRecording` while
  capture is active. VM load refreshes the projection using persisted content and
  pending edit scopes. The root detail's identity is the stable meeting ID.
- The same native inline editor is used before and after recording. No explicit
  recording-state undo disable or custom Command-Z interception was found.

## Background diagnostic controls

1. Native editor A retains undo and redo when another editor sharing its window
   manager receives programmatic live text updates.
2. A recording-state real repository + VM + TranscriptView retains a manual
   edit's undo/redo while another speaker's grouped turn receives new text.
3. The real MeetingDetailView, including its ScrollView and live state, retains
   first-responder identity and undo after native deleteBackward, unattributed
   transcript append, observation refresh, and scheduled 350 ms autosave.
   Command routing through the hidden window's current first responder restores
   the text; redo persists the deletion without discarding later transcription.

All three controls passed individually on the unchanged production source.
Final related background suites: 86 passed, 0 failed, exit 0. Whitespace check
passes, HEAD remains `fa7f420deb5faf65b15998c085e41676d3c8d716`, and Beta 25's
SHA256 is unchanged:
`03e4a650c5b24549bd89b5975384f8b3990a92341d83f242a216442cbd33485d`.
This does NOT reproduce or refute the user's packaged-app failure and does NOT
verify global shortcut/menu routing in a real key window. No visible/key window
or synthetic key event may be used to fill that gap without changing user scope.

## Current outcome

Root cause remains unconfirmed. Production source changes: NONE. Candidate
remains Beta 25. Need human observation of the real recording-state Edit/Undo
menu (disabled vs enabled-but-no-effect vs restoration overwritten) before
choosing a production fix. No speculative code change or new package.

## Subsequent human confirmation

The user subsequently reported “功能已正常，请推送正式版”. The manual gate is now
accepted by the user, and stable promotion is authorized. This does not establish
a new root cause or imply any additional production fix during the investigation.
