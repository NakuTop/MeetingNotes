# Transcription, Permission, and Finalizing Delete Fixes Implementation Plan

> **Execution:** REQUIRED SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Improve Chinese-English transcription accuracy, stop falsely reporting Screen Recording denial, and allow a stranded processing meeting to be deleted safely.

**Architecture:** Keep the full multilingual Whisper model, but classify each ten-second audio window and decode only when Chinese or English is the detected language. Replace Boolean ScreenCaptureKit probing with a structured result so only `SCStreamErrorUserDeclined` is treated as a permission denial, and embed a stable local designated requirement in acceptance builds. Permit deletion of stranded finalization/summary states while asking the coordinator whether any live recording resources still make deletion unsafe.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, ScreenCaptureKit, WhisperKit, SwiftData, XCTest, XcodeGen.

---

### Task 1: Chinese-English high-accuracy transcription policy

**Files:**
- Modify: `MeetingNotes/Transcription/WhisperKitTranscriptionService.swift`
- Modify: `MeetingNotes/Transcription/TranscriptTextSanitizer.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Test: `MeetingNotesTests/TranscriptTextSanitizerTests.swift`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Steps:**
1. Add failing tests proving that language probabilities accept only top-ranked `zh` or `en`, unsupported languages produce no draft, and decoding is fixed to `.transcribe` with automatic all-language selection disabled.
2. Add a failing test proving the production live window is ten seconds.
3. Run the focused tests and confirm they fail for the missing policy and old five-second window.
4. Implement `WhisperLanguagePolicy`, retain the recommended full model (`model == nil`), remove Unicode-script post-filtering, and use a ten-second production window.
5. Run the focused tests and confirm they pass.

### Task 2: Accurate ScreenCaptureKit permission classification

**Files:**
- Modify: `MeetingNotes/Permissions/CapturePermissionClient.swift`
- Modify: `MeetingNotes/Recording/ScreenAudioCaptureSource.swift`
- Modify: `Configuration/MeetingNotesRequirements.req`
- Modify: `project.yml`
- Test: `MeetingNotesTests/CapturePermissionClientTests.swift`
- Test: `MeetingNotesTests/ScreenAudioCaptureConfigurationTests.swift`

**Steps:**
1. Add failing tests for probe success with stale CoreGraphics state, post-request probe success, `userDeclined`, and non-permission ScreenCaptureKit failures.
2. Run the focused tests and confirm the new cases fail.
3. Implement a structured screen-capture probe and map only `SCStreamErrorDomain/-3801` to permission denial.
4. Make online permission requests probe once before requesting, then probe once after a denied request, without duplicating the status probe.
5. Add a local-only explicit designated requirement for `com.shenminghao.MeetingNotes` so successive ad-hoc acceptance builds have a stable privacy identity.
6. Run the focused tests and verify two differently signed local code objects satisfy the same requirement.

### Task 3: Safe deletion of a stranded processing meeting

**Files:**
- Modify: `MeetingNotes/ViewModels/MeetingLibraryViewModel.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinator.swift`
- Modify: `MeetingNotes/App/AppContainer.swift`
- Test: `MeetingNotesTests/MeetingLibraryViewModelTests.swift`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`

**Steps:**
1. Add a failing test proving a persisted `.finalizing` meeting can be deleted and clears selection.
2. Preserve a failing/green regression proving `.preparing`, `.recording`, and `.paused` remain undeletable.
3. Add a coordinator deletion-safety protocol and tests proving released stranded resources are safe while live resources are not.
4. Update the view model to await the deletion-safety check before deleting files and SwiftData records.
5. Run the focused tests and confirm they pass.

### Task 4: Preserve offline recording fidelity and complete verification

**Files:**
- Modify: `MeetingNotes/Recording/CapturedAudioFrame.swift`
- Modify: `MeetingNotes/Recording/MicrophoneCaptureSource.swift`
- Modify: `MeetingNotes/Recording/PCMConverter.swift`
- Modify: `MeetingNotes/Recording/SegmentedPCMWriter.swift`
- Modify: `MeetingNotes/Coordinator/MeetingCoordinatorDependencies.swift`
- Test: `MeetingNotesTests/PCMConverterTests.swift`
- Test: `MeetingNotesTests/MeetingCoordinatorTests.swift`
- Test: `MeetingNotesUITests/MeetingFlowUITests.swift`

**Steps:**
1. Add/retain tests proving offline storage uses 48 kHz while Whisper receives 16 kHz mono samples and online capture remains 16 kHz.
2. Keep storage and transcription sample paths separate so recording fidelity does not change Whisper input format.
3. Run all unit tests, then the complete UI suite on the Apple Silicon Mac.
4. Build a signed arm64 Debug acceptance app, verify architecture, signature, entitlements, and designated requirement.
5. Copy it to the latest acceptance-package path and open that exact binary for manual validation.
