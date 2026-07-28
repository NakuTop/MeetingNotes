import Foundation

struct SpeakerInterval: Equatable, Sendable {
    let rawSpeakerID: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum SpeakerDiarizationError: Error, Equatable, Sendable {
    case modelPreparationFailed
    case inferenceFailed
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
}

extension MeetingAudioSourceLoader: MeetingTrackAudioSourceLoading {}
