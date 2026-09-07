# Pure system audio and direct window screenshots

Status: user approved the pure-audio alternative and direct point-and-click window selection.

## Scope

Continue in the existing `codex/beta-1.3.1-performance` worktree, preserving Beta 21 and all accumulated edits. No commits, publication, installation, actual capture, visible test windows or permission changes during automated validation.

## Online audio

Replace the production online screen-stream backend with a Core Audio process tap. The tap is private, excludes this app and is unmuted: ordinary speaker/headphone playback must continue. Attach it to a private, ephemeral aggregate input. Reuse the already-reviewed AUHAL session/real-time SPSC transport to read that input; keep the adaptive microphone, PCM amplitude policy, synchronizer, mixer, per-track recording and Whisper path unchanged. No SCStream, display enumeration or screen-permission probe may run during online capture startup. No automatic screen-stream fallback.

Core Audio owns the first-use system-audio permission request at capture startup. Add the public `NSAudioCaptureUsageDescription`; microphone authorization remains an explicit preflight. Do not pretend system-audio authorization has already been granted or use private TCC APIs. Screen permission remains applicable to screenshots and the existing separately invoked screen diagnostic. Show actionable system-audio errors without mislabeling them as microphone or display disconnection. Diagnostic semantics and upload schema are not redesigned in this batch.

Each start attempt owns its tap, aggregate and input reader. Cancellation/stop must stop the reader before destroying its aggregate/tap, with idempotent cleanup, token guards, and no late mutation into a restarted session. Never change the user's default audio device, mute output, persist an aggregate, or log device identifiers. Buffer/converter work stays off the main actor and real-time callback retains the existing preallocated transport.

## Screenshots

Replace the sharing picker with a short-lived in-app window-selection overlay, shown only following the user's screenshot action. Highlight the frontmost eligible window under the pointer; one click selects it and Escape cancels. Use existing screen permission and public window metadata; do not require Accessibility/Input Monitoring or automatically approve any OS permission prompt. No live thumbnail streams or persistent desktop capture. Resolve the selected window again before one-shot `SCScreenshotManager` capture. Preserve pixel caps, PNG encoding, Notion sizing, privacy boundaries and note timeline behavior.

Retain robust one-request-at-a-time completion, cancellation and stale-result isolation. Dismiss all selection surfaces before capture; do not capture the selection overlay itself. Multi-display coordinate conversion, overlap/stacking, own-app exclusion and disappeared windows require deterministic policy tests. Preserve the native frosted visual style.

## Validation and delivery

Background-only RED/GREEN tests, full noninteractive units, ordinary Debug build, source review, Beta 1.3.1 (22) local packaging and mounted validation. Production identity remains 1.3.0 (18). No automated hardware acceptance or smoothness claim. User verifies real online sound, no ongoing desktop sharing, speaker output, pause/resume/stop, and direct window selection in packaged Beta 22. System audio permission may require first-use approval; screenshots retain normal OS permission requirements.
