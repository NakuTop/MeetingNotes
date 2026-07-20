# Online Microphone Fidelity Design

## Goal

Raise the microphone track in online meetings to the same storage fidelity and
perceived level as offline meetings, while preserving the current system-audio
quality and the existing Chinese/English transcription behavior.

## Confirmed root cause

Offline meetings store microphone audio at 48 kHz and provide a separate 16 kHz
transcription signal. Online meetings currently configure ScreenCaptureKit,
both source converters, the real-time mixer, and the writer at 16 kHz. The
online mixer also reduces the microphone contribution to 50 percent whenever
system audio is active. The online microphone therefore loses bandwidth and
level before it reaches storage.

## Approved approach

Use a dual-rate online pipeline:

1. Configure ScreenCaptureKit to deliver 48 kHz mono audio for both system and
   microphone sources.
2. Decode both sources to 48 kHz without speech leveling or automatic gain.
3. Align and mix both sources at 48 kHz. Preserve the microphone at full level.
4. Apply a transparent peak limiter only when the combined signal would clip,
   avoiding the current hard-clamp distortion while retaining normal-level
   samples unchanged.
5. Store the mixed 48 kHz frame in the existing segmented CAF format.
6. Derive a separate 16 kHz mono transcription payload from the mixed frame and
   attach it through `CapturedAudioFrame.transcriptionSamples`.
7. Keep Whisper input and the existing Chinese/English language constraints at
   16 kHz.

## Components

### Screen audio configuration and decoding

`ScreenAudioCaptureConfiguration` will use the playback/storage sample rate of
48 kHz. `ScreenAudioSampleDecoder` will convert the system and microphone
sample buffers to the same 48 kHz mono format with amplitude preservation.

### Real-time mixer

`RealtimeAudioMixer` will operate at 48 kHz. When both sources are present, it
will combine the microphone at full level with system audio. If the combined
window exceeds the permitted peak, the limiter will scale only that window to
prevent clipping. Silence, microphone-only, and system-only windows remain
unchanged.

### Transcription conversion

The online capture source will convert each emitted 48 kHz mixed storage frame
to a 16 kHz transcription frame. The storage samples and transcription samples
will share the same timeline and travel together in one `CapturedAudioFrame`,
matching the established offline coordinator contract.

### Coordinator and persistence

The coordinator will create new online writers at 48 kHz. Existing 16 kHz
online recordings remain supported by the current manifest loader; no data
migration is required.

## Failure handling

Conversion or mixing failures continue through the existing online capture
failure path. Pause, resume, stop, queue capacity, and permission behavior are
unchanged. The transcription converter resets together with the two source
converters at every lifecycle boundary.

## Verification boundary

Implementation may use focused deterministic checks for sample-rate contracts,
mixing math, limiter behavior, and transcription payload generation, plus an
arm64 build check. Codex will not start the app, create recordings, play audio,
or perform subjective audio acceptance. Final online microphone quality will be
accepted manually by the user.

## Compatibility

- New online recordings: 48 kHz mono CAF storage plus 16 kHz transcription.
- Existing online recordings: unchanged 16 kHz playback compatibility.
- Offline meetings: no behavioral change.
- System audio: retained at full 48 kHz source quality, subject only to the
  limiter when a combined peak would otherwise clip.
