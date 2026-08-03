# Meeting Start and Unconditional Delete Design

## Problem

Starting either an offline or online meeting creates a persistent meeting record before audio preparation finishes, but the library waits for the entire start pipeline before selecting that record. When audio setup stalls, the window therefore appears stuck on the home screen. If the app is then closed, an unnamed meeting can remain in `preparing` state.

Deletion is currently disabled for `preparing`, `recording`, and `paused` meetings and is rejected while the coordinator owns resources. This makes those residual records impossible to remove from the app and leaves their local files behind when files do exist.

## Confirmed Behavior

- As soon as the new meeting record exists, select it and show its detail/recording screen while audio setup continues.
- Allow the user to request deletion for a meeting in every recording state, including `preparing`, `recording`, `paused`, `finalizing`, `transcribing`, `failed`, and `completed`.
- Keep the existing destructive confirmation before deletion.
- If the target is the meeting currently owned by the recorder, immediately stop and discard it after confirmation.
- Active deletion must not run final transcription, speaker diarization, summary generation, or Notion archival.
- Permanently delete the complete local meeting directory and then the persistent meeting record.
- Existing Notion pages remain unchanged because they are remote records outside local deletion scope.
- If local file deletion fails, keep the database record so the user can retry instead of hiding orphaned files.

## Architecture

### Progressive start presentation

Extend the meeting-start boundary with an `onMeetingCreated` callback. `MeetingCoordinator` invokes it immediately after the repository creates the `preparing` record. `MeetingLibraryViewModel` reloads the library and selects that identifier from the callback, rather than waiting for capture and writer setup to finish.

The original async `start` call still represents completion or failure of the startup pipeline. On failure the view model reloads state and reports the error, while the created meeting remains visible and deletable if cleanup did not remove it.

### Deletion preparation instead of deletion permission

Replace the coordinator's passive `canDeleteMeeting` guard with an async deletion-preparation operation. For inactive or stale records it is a no-op. For the currently preparing or recording meeting it cancels startup/background work, stops capture without invoking the normal finalization path, closes writers, cancels queued transcription for that meeting, hides the floating panel, and releases coordinator state.

The library exposes deletion in every recording state. After confirmation it deselects the target so detail-scoped tasks are cancelled, waits for any meeting operation already holding the per-meeting gate to release it, asks the coordinator to prepare the meeting for deletion, stops playback, deletes the local directory, and finally deletes the repository record.

### Race safety

Startup and deletion can overlap. The coordinator checks cancellation/ownership after each awaited setup boundary, and deletion preparation is idempotent. Once deletion begins, the startup task must not restart capture or recreate files. The transcription queue gains targeted cancellation so discarded audio cannot later write transcript state back to the deleted meeting.

## UI Behavior

- Both meeting-type buttons navigate to the new meeting as soon as its row is created.
- Delete remains available in swipe actions and context menus for all states.
- The confirmation copy explains that an active recording will be stopped and all local content discarded; a Notion page, if one exists, is not removed.
- After confirmed deletion, selection moves away from the removed meeting and the library refreshes.

## Error Handling

- A startup error is shown without returning the user to an apparently frozen home screen.
- Failure to stop or prepare an active meeting aborts physical deletion and surfaces a retryable error.
- Failure to delete local files aborts repository deletion, preserving a visible record for retry.
- Repository deletion runs only after local cleanup succeeds.

## Test Strategy

- View-model test: selection is updated from the record-created callback before the starter returns.
- View-model tests: deletion is available for every recording state and retains file-before-repository ordering.
- View-model test: deletion waits for coordinator preparation and stops playback before file deletion.
- Coordinator tests: deleting a preparing, recording, or paused active meeting discards resources without final transcription or diarization.
- Coordinator race test: deletion during startup prevents late capture/writer work from reviving the meeting.
- Queue test: targeted cancellation removes pending work for the deleted meeting.
- Regression tests: completed/failed/stale meetings still delete normally, and a local file deletion error preserves the repository record.

## Alternatives Rejected

- Launch-time recovery alone would make old residual records removable only after restarting and would not solve the frozen start screen or active deletion.
- Removing UI guards without coordinator cleanup would race capture and transcription against file/database deletion, risking regenerated files and inconsistent state.
