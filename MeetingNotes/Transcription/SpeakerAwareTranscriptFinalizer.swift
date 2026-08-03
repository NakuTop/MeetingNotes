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

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft],
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome
}

extension MeetingSpeakerFinalizing {
    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft],
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome {
        _ = transcriptionService
        return await finalize(
            meetingID: meetingID,
            mode: mode,
            diarizationRequested: diarizationRequested,
            provisional: provisional
        )
    }
}

struct SpeakerAwareTranscriptFinalizer: MeetingSpeakerFinalizing {
    static let coarseSourceRevision = 1
    static let diarizationUnavailableCode =
        "speaker_diarization_unavailable"
    static let diarizationModelPreparationFailedCode =
        "speaker_diarization_model_preparation_failed"
    static let diarizationInvalidSourceCode =
        "speaker_diarization_invalid_source"
    static let diarizationTimelineAssemblyFailedCode =
        "speaker_diarization_timeline_assembly_failed"
    static let diarizationConversionFailedCode =
        "speaker_diarization_conversion_failed"
    static let diarizationInferenceFailedCode =
        "speaker_diarization_inference_failed"
    static let diarizationResultValidationFailedCode =
        "speaker_diarization_result_validation_failed"
    static let diarizationFailedCode =
        "speaker_diarization_failed"

    private let reader: any MeetingTrackAudioReading
    private let transcriptionService: (any TranscriptionService)?
    private let sourceLoader: (any MeetingTrackAudioSourceLoading)?
    private let diarizer: (any SpeakerDiarizing)?
    private let merger: TranscriptMerger
    private let assembler: SpeakerTranscriptAssembler
    private let intervalAssigner: SpeakerIntervalAssigner

    init(
        reader: any MeetingTrackAudioReading,
        transcriptionService: (any TranscriptionService)? = nil,
        sourceLoader: (any MeetingTrackAudioSourceLoading)? = nil,
        diarizer: (any SpeakerDiarizing)? = nil,
        merger: TranscriptMerger = TranscriptMerger(),
        assembler: SpeakerTranscriptAssembler =
            SpeakerTranscriptAssembler(),
        intervalAssigner: SpeakerIntervalAssigner =
            SpeakerIntervalAssigner()
    ) {
        self.reader = reader
        self.transcriptionService = transcriptionService
        self.sourceLoader = sourceLoader
        self.diarizer = diarizer
        self.merger = merger
        self.assembler = assembler
        self.intervalAssigner = intervalAssigner
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        guard mode == .online else {
            return await finalizeOffline(
                meetingID: meetingID,
                diarizationRequested: diarizationRequested,
                provisional: provisional
            )
        }
        guard let transcriptionService else {
            return .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: "source_track_transcription_failed_microphone"
            )
        }
        return await finalizeOnline(
            meetingID: meetingID,
            diarizationRequested: diarizationRequested,
            transcriptionService: transcriptionService
        )
    }

    func finalize(
        meetingID: UUID,
        mode: MeetingMode,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft],
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome {
        guard mode == .online else {
            return await finalizeOffline(
                meetingID: meetingID,
                diarizationRequested: diarizationRequested,
                provisional: provisional
            )
        }
        return await finalizeOnline(
            meetingID: meetingID,
            diarizationRequested: diarizationRequested,
            transcriptionService: transcriptionService
        )
    }

    private func finalizeOnline(
        meetingID: UUID,
        diarizationRequested: Bool,
        transcriptionService: any TranscriptionService
    ) async -> SpeakerFinalizationOutcome {
        var attributedTracks: [AttributedTranscriptDraft] = []
        var mergedSystemDrafts: [TranscriptDraft] = []
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
                let mergedDrafts = merger.merge(drafts)
                if track == .system {
                    mergedSystemDrafts = mergedDrafts
                }
                let identity = Self.coarseIdentity(for: track)
                attributedTracks.append(
                    contentsOf: mergedDrafts.map {
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

        let coarseReplacement = assembler.assemble(attributedTracks)
        guard diarizationRequested else {
            return .replacement(
                coarseReplacement,
                sourceRevision: Self.coarseSourceRevision
            )
        }
        guard let sourceLoader, let diarizer else {
            return .degraded(
                replacement: coarseReplacement,
                sourceRevision: Self.coarseSourceRevision,
                errorCode: Self.diarizationUnavailableCode
            )
        }

        let systemSource: MeetingAudioSource
        do {
            systemSource = try await sourceLoader.load(
                meetingID: meetingID,
                track: .system
            )
        } catch {
            return .degraded(
                replacement: coarseReplacement,
                sourceRevision: Self.coarseSourceRevision,
                errorCode: Self.diarizationInvalidSourceCode
            )
        }

        do {
            let intervals = try await diarizer.diarize(
                source: systemSource
            )
            guard !intervals.isEmpty else {
                throw SpeakerDiarizationError.resultValidationFailed
            }
            let microphoneDrafts = attributedTracks.filter {
                $0.source == .microphone
            }
            let diarizedSystemDrafts = intervalAssigner.assign(
                mergedSystemDrafts,
                intervals: intervals,
                speakerPrefix: "remote",
                source: .system
            )
            return .replacement(
                assembler.assemble(
                    microphoneDrafts + diarizedSystemDrafts
                ),
                sourceRevision: Self.coarseSourceRevision
            )
        } catch {
            return .degraded(
                replacement: coarseReplacement,
                sourceRevision: Self.coarseSourceRevision,
                errorCode: Self.diarizationErrorCode(for: error)
            )
        }
    }

    private func finalizeOffline(
        meetingID: UUID,
        diarizationRequested: Bool,
        provisional: [TranscriptDraft]
    ) async -> SpeakerFinalizationOutcome {
        guard diarizationRequested else {
            return .unchanged
        }
        guard let sourceLoader, let diarizer else {
            return .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: Self.diarizationUnavailableCode
            )
        }

        let masterSource: MeetingAudioSource
        do {
            masterSource = try await sourceLoader.load(
                meetingID: meetingID,
                track: .master
            )
        } catch {
            return .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: Self.diarizationInvalidSourceCode
            )
        }

        do {
            let intervals = try await diarizer.diarize(
                source: masterSource
            )
            guard !intervals.isEmpty else {
                throw SpeakerDiarizationError.resultValidationFailed
            }
            return .replacement(
                assembler.assemble(
                    intervalAssigner.assign(
                        provisional,
                        intervals: intervals,
                        speakerPrefix: "room",
                        source: .room
                    )
                ),
                sourceRevision: Self.coarseSourceRevision
            )
        } catch {
            return .degraded(
                replacement: nil,
                sourceRevision: nil,
                errorCode: Self.diarizationErrorCode(for: error)
            )
        }
    }

    static func diarizationErrorCode(
        for error: Error
    ) -> String {
        switch error {
        case SpeakerDiarizationError.modelPreparationFailed:
            diarizationModelPreparationFailedCode
        case SpeakerDiarizationError.invalidSource:
            diarizationInvalidSourceCode
        case SpeakerDiarizationError.timelineAssemblyFailed:
            diarizationTimelineAssemblyFailedCode
        case SpeakerDiarizationError.conversionFailed:
            diarizationConversionFailedCode
        case SpeakerDiarizationError.inferenceFailed:
            diarizationInferenceFailedCode
        case SpeakerDiarizationError.resultValidationFailed:
            diarizationResultValidationFailedCode
        default:
            diarizationFailedCode
        }
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
