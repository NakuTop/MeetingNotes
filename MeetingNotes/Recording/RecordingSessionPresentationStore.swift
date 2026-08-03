import Foundation
import Observation

enum RecordingSessionPresentationPhase: Equatable, Sendable {
    case recording
    case paused
    case finished
}

protocol RecordingSessionPresentationUpdating: Sendable {
    func start(meetingID: UUID, monotonicTime: TimeInterval) async
    func pause(meetingID: UUID, activeDuration: TimeInterval) async
    func resume(
        meetingID: UUID,
        activeDuration: TimeInterval,
        monotonicTime: TimeInterval
    ) async
    func finish(meetingID: UUID, activeDuration: TimeInterval) async
    func clear(meetingID: UUID) async
}

@MainActor
@Observable
final class RecordingSessionPresentationStore:
    RecordingSessionPresentationUpdating {
    private(set) var meetingID: UUID?
    private(set) var phase: RecordingSessionPresentationPhase?
    private var accumulatedActiveDuration: TimeInterval = 0
    private var resumeMonotonicTime: TimeInterval?

    func start(meetingID: UUID, monotonicTime: TimeInterval) async {
        self.meetingID = meetingID
        phase = .recording
        accumulatedActiveDuration = 0
        resumeMonotonicTime = Self.sanitized(monotonicTime)
    }

    func pause(meetingID: UUID, activeDuration: TimeInterval) async {
        guard self.meetingID == meetingID else { return }
        accumulatedActiveDuration = Self.sanitized(activeDuration)
        resumeMonotonicTime = nil
        phase = .paused
    }

    func resume(
        meetingID: UUID,
        activeDuration: TimeInterval,
        monotonicTime: TimeInterval
    ) async {
        guard self.meetingID == meetingID else { return }
        accumulatedActiveDuration = Self.sanitized(activeDuration)
        resumeMonotonicTime = Self.sanitized(monotonicTime)
        phase = .recording
    }

    func finish(meetingID: UUID, activeDuration: TimeInterval) async {
        guard self.meetingID == meetingID else { return }
        accumulatedActiveDuration = Self.sanitized(activeDuration)
        resumeMonotonicTime = nil
        phase = .finished
    }

    func clear(meetingID: UUID) async {
        guard self.meetingID == meetingID else { return }
        self.meetingID = nil
        phase = nil
        accumulatedActiveDuration = 0
        resumeMonotonicTime = nil
    }

    func activeDuration(
        for meetingID: UUID,
        at monotonicTime: TimeInterval
    ) -> TimeInterval? {
        guard self.meetingID == meetingID else { return nil }
        guard phase == .recording,
              let resumeMonotonicTime else {
            return accumulatedActiveDuration
        }
        let elapsed = max(
            0,
            Self.sanitized(monotonicTime) - resumeMonotonicTime
        )
        return accumulatedActiveDuration + elapsed
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}

struct NoopRecordingSessionPresentationUpdater:
    RecordingSessionPresentationUpdating {
    func start(meetingID: UUID, monotonicTime: TimeInterval) async {
        _ = meetingID
        _ = monotonicTime
    }

    func pause(meetingID: UUID, activeDuration: TimeInterval) async {
        _ = meetingID
        _ = activeDuration
    }

    func resume(
        meetingID: UUID,
        activeDuration: TimeInterval,
        monotonicTime: TimeInterval
    ) async {
        _ = meetingID
        _ = activeDuration
        _ = monotonicTime
    }

    func finish(meetingID: UUID, activeDuration: TimeInterval) async {
        _ = meetingID
        _ = activeDuration
    }

    func clear(meetingID: UUID) async {
        _ = meetingID
    }
}
