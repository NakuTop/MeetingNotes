import Foundation
import Observation

enum ScreenshotCaptureState: Equatable, Sendable {
    case idle
    case capturing
    case saved
    case permissionRequired
    case failed(message: String)
}

@MainActor
@Observable
final class RecordingAnnotationViewModel {
    typealias MonotonicTime = @MainActor @Sendable () -> TimeInterval
    typealias IDGenerator = @MainActor @Sendable () -> UUID
    typealias Now = @MainActor @Sendable () -> Date
    typealias ScreenshotFeedbackDelay =
        @MainActor @Sendable (Duration) async throws -> Void

    private struct SessionSnapshot: Equatable {
        let meetingID: UUID
        let activeDuration: TimeInterval
        let generation: UUID
    }

    private struct NoteContext: Equatable {
        let meetingID: UUID
        let noteID: UUID
        let timestamp: TimeInterval
        let sequenceIndex: Int
        let generation: UUID
    }

    private static let screenshotFailureMessage =
        "截图未保存，请稍后重试。"

    private let repository: MeetingRepository
    private let fileStore: MeetingFileStore
    private let screenshotCapture: any MeetingScreenshotCapturing
    private let presentationStore: RecordingSessionPresentationStore
    private let noteAutosaver: MeetingNoteAutosaver
    private let monotonicTime: MonotonicTime
    private let idGenerator: IDGenerator
    private let now: Now
    private let screenshotFeedbackDelay: ScreenshotFeedbackDelay

    private var observedActiveMeetingID: UUID?
    private var sessionGeneration = UUID()
    private var noteContext: NoteContext?
    private var screenshotFeedbackToken = UUID()
    private var screenshotFeedbackTask: Task<Void, Never>?

    private(set) var isNoteEditorPresented = false
    private(set) var noteDraft = ""
    private(set) var screenshotState: ScreenshotCaptureState = .idle

    var noteSaveState: MeetingLocalSaveState {
        noteAutosaver.state
    }

    init(
        repository: MeetingRepository,
        fileStore: MeetingFileStore,
        screenshotCapture: any MeetingScreenshotCapturing =
            MeetingScreenshotCaptureService(),
        presentationStore: RecordingSessionPresentationStore,
        noteDelay: @escaping MeetingNoteAutosaver.Delay = { duration in
            try await Task.sleep(for: duration)
        },
        onNoteDelayedTaskCompletion:
            @escaping MeetingNoteAutosaver.DelayedTaskCompletion = {},
        screenshotFeedbackDelay:
            @escaping ScreenshotFeedbackDelay = { duration in
                try await Task.sleep(for: duration)
            },
        monotonicTime: @escaping MonotonicTime = {
            ProcessInfo.processInfo.systemUptime
        },
        idGenerator: @escaping IDGenerator = { UUID() },
        now: @escaping Now = { .now }
    ) {
        self.repository = repository
        self.fileStore = fileStore
        self.screenshotCapture = screenshotCapture
        self.presentationStore = presentationStore
        noteAutosaver = MeetingNoteAutosaver(
            delay: noteDelay,
            onDelayedTaskCompletion: onNoteDelayedTaskCompletion
        )
        self.screenshotFeedbackDelay = screenshotFeedbackDelay
        self.monotonicTime = monotonicTime
        self.idGenerator = idGenerator
        self.now = now
        observedActiveMeetingID = Self.activeMeetingID(
            in: presentationStore
        )
    }

    func refreshForCurrentSession() {
        synchronizeSession()
    }

    func beginNote() {
        guard !isNoteEditorPresented,
              let snapshot = currentSessionSnapshot() else {
            return
        }
        let sequenceIndex = (try? repository.notes(
            meetingID: snapshot.meetingID
        ).count) ?? 0
        noteContext = NoteContext(
            meetingID: snapshot.meetingID,
            noteID: idGenerator(),
            timestamp: snapshot.activeDuration,
            sequenceIndex: sequenceIndex,
            generation: snapshot.generation
        )
        noteDraft = ""
        noteAutosaver.cancel()
        isNoteEditorPresented = true
    }

    func updateNoteDraft(_ text: String) {
        noteDraft = text
        guard let context = noteContext,
              isCurrent(context) else {
            return
        }
        let request = MeetingNoteSaveRequest(
            meetingID: context.meetingID,
            noteID: context.noteID,
            timestamp: context.timestamp,
            text: text,
            sequenceIndex: context.sequenceIndex
        )
        noteAutosaver.schedule(request) { [weak self] request in
            guard let self,
                  let currentContext = self.noteContext,
                  currentContext.noteID == request.noteID,
                  self.isCurrent(currentContext) else {
                return
            }
            try self.repository.upsertNote(
                meetingID: request.meetingID,
                id: request.noteID,
                timestamp: request.timestamp,
                text: request.text,
                sequenceIndex: request.sequenceIndex,
                now: self.now()
            )
        }
    }

    func submitNote() async {
        await noteAutosaver.flush()
        guard let context = noteContext,
              isCurrent(context) else {
            return
        }
        switch noteAutosaver.state {
        case .idle, .saved:
            isNoteEditorPresented = false
            noteContext = nil
            noteDraft = ""
        case .saving, .failed:
            break
        }
    }

    func retryNoteSave() async {
        await noteAutosaver.retry()
    }

    func captureScreenshot() async {
        guard screenshotState != .capturing,
              let snapshot = currentSessionSnapshot() else {
            return
        }
        cancelScreenshotFeedbackReset()
        let screenshotID = idGenerator()
        let createdAt = now()
        screenshotState = .capturing

        let captured: MeetingScreenshotCaptureResult?
        do {
            captured = try await screenshotCapture.captureSelectedWindow()
        } catch {
            updateScreenshotFailure(error, for: snapshot)
            return
        }
        guard let captured else {
            if isCurrent(snapshot) {
                screenshotState = .idle
            }
            return
        }

        let relativePath: String
        do {
            relativePath = try await fileStore.saveScreenshotPNG(
                captured.pngData,
                meetingID: snapshot.meetingID,
                screenshotID: screenshotID
            )
        } catch {
            updateScreenshotFailure(error, for: snapshot)
            return
        }

        guard isCurrent(snapshot) else {
            await removeScreenshotFile(
                meetingID: snapshot.meetingID,
                relativePath: relativePath
            )
            return
        }

        do {
            let sequenceIndex = try repository.screenshots(
                meetingID: snapshot.meetingID
            ).count
            try repository.appendScreenshot(
                meetingID: snapshot.meetingID,
                id: screenshotID,
                timestamp: snapshot.activeDuration,
                relativePath: relativePath,
                pixelWidth: captured.pixelWidth,
                pixelHeight: captured.pixelHeight,
                byteCount: captured.pngData.count,
                sequenceIndex: sequenceIndex,
                createdAt: createdAt
            )
            guard isCurrent(snapshot) else { return }
            screenshotState = .saved
            scheduleScreenshotFeedbackReset(for: snapshot)
        } catch {
            await removeScreenshotFile(
                meetingID: snapshot.meetingID,
                relativePath: relativePath
            )
            updateScreenshotFailure(error, for: snapshot)
        }
    }

    func dismissScreenshotFeedback() {
        switch screenshotState {
        case .permissionRequired, .failed, .saved:
            cancelScreenshotFeedbackReset()
            screenshotState = .idle
        case .idle, .capturing:
            break
        }
    }

    private func currentSessionSnapshot() -> SessionSnapshot? {
        synchronizeSession()
        guard let meetingID = observedActiveMeetingID,
              let activeDuration = presentationStore.activeDuration(
                for: meetingID,
                at: monotonicTime()
              ) else {
            return nil
        }
        return SessionSnapshot(
            meetingID: meetingID,
            activeDuration: Self.sanitized(activeDuration),
            generation: sessionGeneration
        )
    }

    private func isCurrent(_ snapshot: SessionSnapshot) -> Bool {
        synchronizeSession()
        return snapshot.generation == sessionGeneration
            && snapshot.meetingID == observedActiveMeetingID
    }

    private func isCurrent(_ context: NoteContext) -> Bool {
        synchronizeSession()
        return context.generation == sessionGeneration
            && context.meetingID == observedActiveMeetingID
    }

    private func synchronizeSession() {
        let activeMeetingID = Self.activeMeetingID(in: presentationStore)
        guard activeMeetingID != observedActiveMeetingID else { return }
        observedActiveMeetingID = activeMeetingID
        sessionGeneration = UUID()
        noteAutosaver.cancel()
        noteContext = nil
        noteDraft = ""
        isNoteEditorPresented = false
        cancelScreenshotFeedbackReset()
        screenshotState = .idle
    }

    private static func activeMeetingID(
        in store: RecordingSessionPresentationStore
    ) -> UUID? {
        switch store.phase {
        case .recording, .paused:
            store.meetingID
        case .finished, nil:
            nil
        }
    }

    private func updateScreenshotFailure(
        _ error: Error,
        for snapshot: SessionSnapshot
    ) {
        guard isCurrent(snapshot) else { return }
        cancelScreenshotFeedbackReset()
        if error is CancellationError {
            screenshotState = .idle
        } else if error as? MeetingScreenshotCaptureError
                    == .screenRecordingDenied {
            screenshotState = .permissionRequired
        } else {
            screenshotState = .failed(
                message: Self.screenshotFailureMessage
            )
        }
    }

    private func scheduleScreenshotFeedbackReset(
        for snapshot: SessionSnapshot
    ) {
        cancelScreenshotFeedbackReset()
        let token = UUID()
        screenshotFeedbackToken = token
        let delay = screenshotFeedbackDelay
        screenshotFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await delay(.seconds(2))
            } catch {
                return
            }
            guard let self,
                  self.screenshotFeedbackToken == token,
                  self.isCurrent(snapshot),
                  self.screenshotState == .saved else {
                return
            }
            self.screenshotState = .idle
            self.screenshotFeedbackTask = nil
        }
    }

    private func cancelScreenshotFeedbackReset() {
        screenshotFeedbackToken = UUID()
        screenshotFeedbackTask?.cancel()
        screenshotFeedbackTask = nil
    }

    private func removeScreenshotFile(
        meetingID: UUID,
        relativePath: String
    ) async {
        guard let staged = try? await fileStore.stageScreenshotDeletion(
            meetingID: meetingID,
            relativePath: relativePath
        ) else {
            return
        }
        try? await fileStore.commitScreenshotDeletion(staged)
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
