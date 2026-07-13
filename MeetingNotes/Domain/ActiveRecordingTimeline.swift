import Foundation

enum ActiveRecordingTimelineError: Error, Equatable, Sendable {
    case alreadyPaused
    case notPaused
    case nonMonotonicTime
}

struct ActiveRecordingTimeline: Equatable, Sendable {
    let startedAt: TimeInterval
    private(set) var accumulatedPauseDuration: TimeInterval
    private(set) var pausedAt: TimeInterval?
    private var lastTransitionAt: TimeInterval

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        accumulatedPauseDuration = 0
        pausedAt = nil
        lastTransitionAt = startedAt
    }

    mutating func pause(at time: TimeInterval) throws {
        guard pausedAt == nil else {
            throw ActiveRecordingTimelineError.alreadyPaused
        }
        guard time >= lastTransitionAt else {
            throw ActiveRecordingTimelineError.nonMonotonicTime
        }

        pausedAt = time
        lastTransitionAt = time
    }

    mutating func resume(at time: TimeInterval) throws {
        guard let pausedAt else {
            throw ActiveRecordingTimelineError.notPaused
        }
        guard time >= pausedAt else {
            throw ActiveRecordingTimelineError.nonMonotonicTime
        }

        accumulatedPauseDuration += time - pausedAt
        self.pausedAt = nil
        lastTransitionAt = time
    }

    func activeTime(at time: TimeInterval) -> TimeInterval {
        let effectiveTime = pausedAt.map { min(time, $0) } ?? time
        return max(0, effectiveTime - startedAt - accumulatedPauseDuration)
    }
}
