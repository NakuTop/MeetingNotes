import Foundation

enum CaptureHealthStatus: Equatable, Sendable {
    case waitingForFrames
    case observing
    case noFrames
    case sustainedSilence
}

struct CaptureHealthMonitor: Equatable, Sendable {
    static let firstFrameDeadline: TimeInterval = 5
    static let sustainedSilenceWindow: TimeInterval = 5
    static let audiblePeakThreshold: Float = 0.000_01

    private let startedAt: TimeInterval
    private var receivedFrame = false
    private var silentSince: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    mutating func ingest(samples: [Float], at time: TimeInterval) {
        guard !samples.isEmpty else { return }
        receivedFrame = true
        if samples.contains(where: Self.isAudible) {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = time
        }
    }

    func status(at time: TimeInterval) -> CaptureHealthStatus {
        guard receivedFrame else {
            return time - startedAt >= Self.firstFrameDeadline
                ? .noFrames
                : .waitingForFrames
        }
        guard let silentSince,
              time - silentSince >= Self.sustainedSilenceWindow else {
            return .observing
        }
        return .sustainedSilence
    }

    private static func isAudible(_ sample: Float) -> Bool {
        sample.isFinite && abs(sample) >= audiblePeakThreshold
    }
}

enum MeetingCaptureHealthCode: String, Equatable, Sendable {
    case masterNoFrames = "capture_health_master_no_frames"
    case masterSustainedSilence = "capture_health_master_sustained_silence"
    case microphoneNoFrames = "capture_health_microphone_no_frames"
    case microphoneSustainedSilence =
        "capture_health_microphone_sustained_silence"
    case systemNoFrames = "capture_health_system_no_frames"
    case systemSustainedSilence = "capture_health_system_sustained_silence"
    case bothSourcesDegraded = "capture_health_both_sources_degraded"
}

protocol CaptureHealthCheckScheduling: Sendable {
    func checks() -> AsyncStream<Void>
}

struct ContinuousCaptureHealthCheckScheduler:
    CaptureHealthCheckScheduling {
    private let interval: Duration

    init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    func checks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
