import Foundation

enum SpeakerFinalizationOutcome: Equatable, Sendable {
    case unchanged
    case replacement(
        [AttributedTranscriptDraft],
        sourceRevision: Int
    )
    case degraded(
        replacement: [AttributedTranscriptDraft]?,
        sourceRevision: Int?,
        errorCode: String
    )
}

protocol MeetingSpeakerFinalizing: Sendable {
    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome
}

struct SpeakerAwareTranscriptFinalizer: MeetingSpeakerFinalizing {
    static let coarseSourceRevision = 1
    static let diarizationUnavailableCode =
        "speaker_diarization_unavailable"

    private let reader: any MeetingTrackAudioReading
    private let transcriptionService: any TranscriptionService
    private let merger: TranscriptMerger
    private let assembler: SpeakerTranscriptAssembler

    init(
        reader: any MeetingTrackAudioReading,
        transcriptionService: any TranscriptionService,
        merger: TranscriptMerger = TranscriptMerger(),
        assembler: SpeakerTranscriptAssembler =
            SpeakerTranscriptAssembler()
    ) {
        self.reader = reader
        self.transcriptionService = transcriptionService
        self.merger = merger
        self.assembler = assembler
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        _ = provisional
        guard mode == .online else {
            return diarizationRequested
                ? .degraded(
                    replacement: nil,
                    sourceRevision: nil,
                    errorCode: Self.diarizationUnavailableCode
                )
                : .unchanged
        }

        var attributedTracks: [AttributedTranscriptDraft] = []
        for track in [AudioTrack.microphone, .system] {
            do {
                let sequence = try await reader.chunks(
                    meetingID: meetingID,
                    track: track
                )
                var drafts: [TranscriptDraft] = []
                for try await chunk in sequence {
                    drafts.append(
                        contentsOf: try await transcriptionService.transcribe(
                            samples: chunk.samples,
                            startingAt: chunk.startingAt
                        )
                    )
                }
                let identity = Self.coarseIdentity(for: track)
                attributedTracks.append(
                    contentsOf: merger.merge(drafts).map {
                        AttributedTranscriptDraft(
                            transcript: $0,
                            speakerID: identity.speakerID,
                            source: identity.source
                        )
                    }
                )
            } catch {
                return .degraded(
                    replacement: nil,
                    sourceRevision: nil,
                    errorCode:
                        "source_track_transcription_failed_\(track.rawValue)"
                )
            }
        }

        let replacement = assembler.assemble(attributedTracks)
        if diarizationRequested {
            return .degraded(
                replacement: replacement,
                sourceRevision: Self.coarseSourceRevision,
                errorCode: Self.diarizationUnavailableCode
            )
        }
        return .replacement(
            replacement,
            sourceRevision: Self.coarseSourceRevision
        )
    }

    private static func coarseIdentity(
        for track: AudioTrack
    ) -> (speakerID: String, source: TranscriptAudioSource) {
        switch track {
        case .microphone:
            ("me", .microphone)
        case .system:
            ("remote", .system)
        case .master:
            preconditionFailure("Master is not a coarse speaker source")
        }
    }
}
