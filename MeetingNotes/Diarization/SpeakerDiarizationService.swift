import Foundation

struct SpeakerInterval: Equatable, Sendable {
    let rawSpeakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeakerDiarizationError: Error, Equatable, Sendable {
    case invalidSpeakerCount
    case unsupportedSpeakerCount
    case modelPreparationFailed
    case invalidSource
    case timelineAssemblyFailed
    case conversionFailed
    case inferenceFailed
    case resultValidationFailed
}

protocol SpeakerDiarizing: Sendable {
    func diarize(
        source: MeetingAudioSource
    ) async throws -> [SpeakerInterval]

    func diarize(source: MeetingAudioSource, speakerCount: SpeakerCountConstraint) async throws -> [SpeakerInterval]
}

extension SpeakerDiarizing {
    func diarize(source: MeetingAudioSource, speakerCount: SpeakerCountConstraint) async throws -> [SpeakerInterval] {
        guard speakerCount == .automatic else { throw SpeakerDiarizationError.unsupportedSpeakerCount }
        return try await diarize(source: source)
    }
}

enum SpeakerCountConstraint: Codable, Equatable, Sendable {
    case automatic
    case exact(Int)
    case range(Int, Int)

    var isValid: Bool {
        switch self {
        case .automatic: true
        case let .exact(count): (1...20).contains(count)
        case let .range(minimum, maximum): (1...20).contains(minimum) && (minimum...20).contains(maximum)
        }
    }

    var label: String {
        switch self {
        case .automatic: "自动判断"
        case let .exact(count): "\(count) 位发言人"
        case let .range(minimum, maximum): "\(minimum)–\(maximum) 位发言人"
        }
    }

    func accepts(observedCount: Int) -> Bool {
        switch self {
        case .automatic: true
        case let .exact(count): observedCount == count
        case let .range(minimum, maximum): observedCount >= minimum && observedCount <= maximum
        }
    }
}

protocol MeetingTrackAudioSourceLoading: Sendable {
    func load(
        meetingID: UUID,
        track: AudioTrack
    ) async throws -> MeetingAudioSource

    func confirmSegmentIdentity(
        in source: MeetingAudioSource,
        segmentIndex: Int
    ) async throws
}

extension MeetingAudioSourceLoader: MeetingTrackAudioSourceLoading {}
