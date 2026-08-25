# Model-Ready Meeting Start Design

## Problem

When the selected Whisper model is still downloading, `MeetingCoordinator.start`
currently transitions to `.preparing` and creates a persistent meeting before
`LiveMeetingTranscriptionQueueFactory.makeQueue()` returns. The library selects
that record immediately, but capture and floating-panel presentation occur only
after the transcription service is ready.

This produces a meeting detail with no floating controls. Settings are disabled
because `.preparing` blocks capture-setting changes. Deletion cannot finish
promptly because `prepareForDeletion` must wait for the in-progress startup,
while no capture or transcription queue has yet been installed for it to cancel.

## Confirmed Behavior

- Clicking a meeting button may initiate or join model preparation.
- Until model preparation succeeds, the coordinator remains `.idle` and owns no
  meeting identifier.
- No meeting record, recording directory, writer, capture source, presentation
  session, or floating panel is created while model preparation is pending.
- The start screen remains visible and its existing model status communicates
  download/load progress.
- Capture settings remain available because no meeting has started.
- Once the model is ready, normal production meeting startup proceeds unchanged:
  permission validation, `.preparing`, record creation, writers, capture,
  `.recording`, presentation state, and floating panel.
- Model preparation failure or caller cancellation leaves the coordinator idle
  and creates no meeting that could reappear in the sidebar.

## Architecture

Move transcription queue creation to the pre-meeting portion of
`MeetingCoordinator.start`, after permission validation but before the
`.prepare` state transition and repository creation. Keep the shared
`TranscriptionModelController` preparation behavior unchanged: an app-level
download can continue and concurrent waiters can share it.

The created queue remains a local startup resource until a meeting is created.
If any later startup boundary fails, the existing cleanup path drains or
cancels the queue as appropriate, finishes its updates, and releases other
resources. No model catalog, decoder, audio capture, timeout, diagnostic,
persistence, or floating-panel behavior changes.

## Race Safety

- `lifecycleOperationInProgress` continues to serialize coordinator starts.
- The `.prepare` transition is validated on a copied state machine before any
  suspension, but is not installed until model and startup metadata are ready;
  a duplicate start therefore cannot reset an existing recording session.
- While model preparation is pending, `meetingID == nil`; deletion therefore has
  no active meeting to target or resurrect.
- A cancelled waiter may allow the shared model preparation to continue, but it
  cannot create a meeting after cancellation because the controller checks
  caller cancellation before returning the service and the coordinator checks
  cancellation after every pre-persistence suspension.
- If cancellation occurs while repository creation is suspended, the returned
  identifier is retained locally before cancellation is checked, allowing the
  existing rollback path to delete the unpublished record.
- Existing discard checks remain responsible for deletion races after a real
  meeting identifier has been created.

## Test Strategy

- Deterministically block transcription queue creation and verify the
  coordinator remains idle, no repository record exists, no writer or capture is
  created, settings are not blocked, and the floating panel is hidden.
- Release the model barrier and verify the same start proceeds normally and
  presents the floating panel.
- Make model preparation fail and verify no meeting record or recording
  resources are created and the coordinator remains idle.
- Verify a rejected second start preserves the original active meeting and that
  it remains stoppable.
- Deterministically cancel both before repository entry and while repository
  creation is suspended, verifying no persisted or runtime session survives.
- Preserve the existing deletion-during-capture-start regression, which covers
  cancellation after a real meeting has been created.

## Alternatives Rejected

- Showing cancellable floating controls for `.preparing` would expand the
  recording state machine and require a new stop/cancel lifecycle.
- Starting capture before model readiness would require durable deferred
  transcription and potentially unbounded buffering.
- Cancelling the shared model download on meeting deletion would break other
  waiters and root-level model preparation without addressing premature meeting
  creation.
