import Foundation

struct SpeakerInterval: Equatable, Sendable {
    let rawSpeakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeakerDiarizationError: Error, Equatable, Sendable {
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
