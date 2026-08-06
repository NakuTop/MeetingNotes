import Foundation
import OSLog

enum SpeakerDiarizationRetryError: Error, Equatable, Sendable {
    case operationInProgress
    case invalidState(SpeakerProcessingState)
    case noFinalTranscript
    case sourceUnavailable
    case failed(errorCode: String)
}

@MainActor
protocol MeetingSpeakerDiarizationRetrying: AnyObject {
    func retry(meetingID: UUID) async throws
}

protocol PreferredTranscriptionServiceProviding: Sendable {
    func service() async throws -> any TranscriptionService
}

struct PreferredTranscriptionServiceProvider:
    PreferredTranscriptionServiceProviding {
    let controller: any TranscriptionModelControlling
    let preference: any TranscriptionQualityPreferenceReading

    func service() async throws -> any TranscriptionService {
        let mode = await preference.transcriptionQualityMode()
        return try await controller.service(mode: mode)
    }
}

@MainActor
final class SpeakerDiarizationRetryUseCase:
    MeetingSpeakerDiarizationRetrying {
    private struct RetryReplacement {
        let drafts: [AttributedTranscriptDraft]
        let degradationErrorCode: String?
    }

    private static let logger = Logger(
        subsystem: "MeetingNotes",
        category: "SpeakerDiarizationRetry"
    )
    static let sourceUnavailableCode =
        "speaker_diarization_source_unavailable"
    static let transcriptUnavailableCode =
        "speaker_diarization_transcript_unavailable"
    static let cancelledCode = "speaker_diarization_cancelled"
    static let transcriptReplacementFailedCode =
        "speaker_transcript_replacement_failed"

    private let repository: MeetingRepository
    private let sourceLoader: any MeetingTrackAudioSourceLoading
    private let diarizer: any SpeakerDiarizing
    private let operationGate: MeetingOperationGate
    private let intervalAssigner: SpeakerIntervalAssigner
    private let assembler: SpeakerTranscriptAssembler
    private let nameRemapper: SpeakerNameRemapper
    private let onlineRebuilder:
        (any OnlineMeetingTranscriptRebuilding)?
    private let transcriptionServiceProvider:
        (any PreferredTranscriptionServiceProviding)?

    init(
        repository: MeetingRepository,
        sourceLoader: any MeetingTrackAudioSourceLoading,
        diarizer: any SpeakerDiarizing,
        operationGate: MeetingOperationGate,
        intervalAssigner: SpeakerIntervalAssigner = SpeakerIntervalAssigner(),
        assembler: SpeakerTranscriptAssembler = SpeakerTranscriptAssembler(),
        nameRemapper: SpeakerNameRemapper = SpeakerNameRemapper(),
        onlineRebuilder:
            (any OnlineMeetingTranscriptRebuilding)? = nil,
        transcriptionServiceProvider:
            (any PreferredTranscriptionServiceProviding)? = nil
    ) {
        self.repository = repository
        self.sourceLoader = sourceLoader
        self.diarizer = diarizer
        self.operationGate = operationGate
        self.intervalAssigner = intervalAssigner
        self.assembler = assembler
        self.nameRemapper = nameRemapper
        self.onlineRebuilder = onlineRebuilder
        self.transcriptionServiceProvider = transcriptionServiceProvider
    }

    func retry(meetingID: UUID) async throws {
        guard operationGate.acquire(
            .speakerDiarizationRetry,
            for: meetingID
        ) else {
            throw SpeakerDiarizationRetryError.operationInProgress
        }
        defer {
            operationGate.release(
                .speakerDiarizationRetry,
                for: meetingID
            )
        }

        try Task.checkCancellation()
        do {
            try repository.beginSpeakerDiarizationRetry(
                meetingID: meetingID
            )
        } catch let error as MeetingRepositoryError {
            switch error {
            case .meetingNotFound:
                throw SpeakerDiarizationRetryError.failed(
                    errorCode: Self.sourceUnavailableCode
                )
            case let .invalidState(state):
                throw SpeakerDiarizationRetryError.invalidState(state)
            }
        }

        do {
            let meeting = try repository.meeting(id: meetingID)
            let finalTranscripts = try repository.transcripts(
                meetingID: meetingID
            ).filter(\.isFinal)
            guard meeting.mode == .online || !finalTranscripts.isEmpty else {
                throw SpeakerDiarizationRetryError.noFinalTranscript
            }
            let sourceRevision = Self.nextSourceRevision(
                for: finalTranscripts
            )
            let nameEvidence = Self.nameEvidence(
                transcripts: finalTranscripts,
                displayNames: meeting.speakerDisplayNames
            )
            let replacement: RetryReplacement
            switch meeting.mode {
            case .offline:
                replacement = RetryReplacement(
                    drafts: try await retryOffline(
                        meetingID: meetingID,
                        transcripts: finalTranscripts
                    ),
                    degradationErrorCode: nil
                )
            case .online:
                replacement = try await retryOnline(
                    meetingID: meetingID,
                    transcripts: finalTranscripts
                )
            }
            try Task.checkCancellation()
            let remappedNames = nameRemapper.remap(
                oldNamedSpeakers: nameEvidence,
                newDrafts: replacement.drafts
            )
            do {
                try repository.completeSpeakerDiarizationRetry(
                    meetingID: meetingID,
                    drafts: replacement.drafts,
                    sourceRevision: sourceRevision,
                    speakerDisplayNames: remappedNames,
                    degradationErrorCode:
                        replacement.degradationErrorCode
                )
            } catch {
                throw SpeakerDiarizationRetryError.failed(
                    errorCode: Self.transcriptReplacementFailedCode
                )
            }
        } catch is CancellationError {
            do {
                try persistFailure(
                    meetingID: meetingID,
                    errorCode: Self.cancelledCode
                )
            } catch {
                Self.logger.error(
                    "stage=retry_failure_persistence"
                )
            }
            throw CancellationError()
        } catch let error as SpeakerDiarizationRetryError {
            let code = Self.errorCode(for: error)
            try persistFailure(meetingID: meetingID, errorCode: code)
            throw error
        } catch {
            let code = SpeakerAwareTranscriptFinalizer
                .diarizationErrorCode(for: error)
            try persistFailure(meetingID: meetingID, errorCode: code)
            throw SpeakerDiarizationRetryError.failed(errorCode: code)
        }
    }

    private func retryOffline(
        meetingID: UUID,
        transcripts: [TranscriptRecord]
    ) async throws -> [AttributedTranscriptDraft] {
        let source: MeetingAudioSource
        do {
            source = try await sourceLoader.load(
                meetingID: meetingID,
                track: .master
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.invalidSource
        }
        try Task.checkCancellation()
        let intervals = try await diarizer.diarize(source: source)
        guard !intervals.isEmpty else {
            throw SpeakerDiarizationError.resultValidationFailed
        }
        let drafts = transcripts.map(Self.transcriptDraft)
        return assembler.assemble(
            intervalAssigner.assign(
                drafts,
                intervals: intervals,
                speakerPrefix: "room",
                source: .room
            )
        )
    }

    private func retryOnline(
        meetingID: UUID,
        transcripts: [TranscriptRecord]
    ) async throws -> RetryReplacement {
        let tagged = transcripts.compactMap { transcript -> (
            TranscriptRecord,
            TranscriptAudioSource
        )? in
            guard let rawValue = transcript.sourceRawValue,
                  let source = TranscriptAudioSource(rawValue: rawValue),
                  source == .microphone || source == .system else {
                return nil
            }
            return (transcript, source)
        }
        if tagged.count == transcripts.count,
           tagged.contains(where: { $0.1 == .system }) {
            return RetryReplacement(
                drafts: try await reattributeTaggedOnlineTranscripts(
                    meetingID: meetingID,
                    tagged: tagged
                ),
                degradationErrorCode: nil
            )
        }

        return try await rebuildUntaggedOnlineTranscripts(
            meetingID: meetingID
        )
    }

    private func reattributeTaggedOnlineTranscripts(
        meetingID: UUID,
        tagged: [(TranscriptRecord, TranscriptAudioSource)]
    ) async throws -> [AttributedTranscriptDraft] {

        let systemSource: MeetingAudioSource
        do {
            systemSource = try await sourceLoader.load(
                meetingID: meetingID,
                track: .system
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeakerDiarizationError.invalidSource
        }
        try Task.checkCancellation()
        let intervals = try await diarizer.diarize(source: systemSource)
        guard !intervals.isEmpty else {
            throw SpeakerDiarizationError.resultValidationFailed
        }

        let microphoneDrafts: [AttributedTranscriptDraft] = tagged.compactMap {
            item in
            let (record, source) = item
            guard source == .microphone else { return nil }
            return AttributedTranscriptDraft(
                transcript: Self.transcriptDraft(record),
                speakerID: "me",
                source: .microphone
            )
        }
        let systemDrafts: [TranscriptDraft] = tagged.compactMap { item in
            let (record, source) = item
            return source == .system
                ? Self.transcriptDraft(record)
                : nil
        }
        let attributedSystemDrafts = intervalAssigner.assign(
            systemDrafts,
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )
        return assembler.assemble(
            microphoneDrafts + attributedSystemDrafts
        )
    }

    private func rebuildUntaggedOnlineTranscripts(
        meetingID: UUID
    ) async throws -> RetryReplacement {
        guard let onlineRebuilder,
              let transcriptionServiceProvider else {
            throw SpeakerDiarizationRetryError.sourceUnavailable
        }

        for track in [AudioTrack.microphone, .system] {
            do {
                _ = try await sourceLoader.load(
                    meetingID: meetingID,
                    track: track
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SpeakerDiarizationRetryError.sourceUnavailable
            }
        }
        try Task.checkCancellation()

        let service = try await transcriptionServiceProvider.service()
        try Task.checkCancellation()
        let outcome = await onlineRebuilder.rebuild(
            meetingID: meetingID,
            diarizationRequested: true,
            transcriptionService: service
        )
        try Task.checkCancellation()

        switch outcome {
        case let .replacement(drafts, _):
            guard !drafts.isEmpty else {
                throw SpeakerDiarizationRetryError.noFinalTranscript
            }
            return RetryReplacement(
                drafts: drafts,
                degradationErrorCode: nil
            )
        case let .degraded(replacement?, _, errorCode):
            guard !replacement.isEmpty else {
                throw SpeakerDiarizationRetryError.failed(
                    errorCode: errorCode
                )
            }
            return RetryReplacement(
                drafts: replacement,
                degradationErrorCode: errorCode
            )
        case let .degraded(nil, _, errorCode):
            throw SpeakerDiarizationRetryError.failed(
                errorCode: errorCode
            )
        case .unchanged:
            throw SpeakerDiarizationRetryError.failed(
                errorCode: SpeakerAwareTranscriptFinalizer
                    .diarizationFailedCode
            )
        }
    }

    private func persistFailure(
        meetingID: UUID,
        errorCode: String
    ) throws {
        do {
            try repository.failSpeakerDiarizationRetry(
                meetingID: meetingID,
                errorCode: errorCode
            )
        } catch {
            guard !isFailurePersisted(
                meetingID: meetingID,
                errorCode: errorCode
            ) else {
                return
            }

            do {
                try repository.failSpeakerDiarizationRetry(
                    meetingID: meetingID,
                    errorCode: errorCode
                )
            } catch {
                guard !isFailurePersisted(
                    meetingID: meetingID,
                    errorCode: errorCode
                ) else {
                    return
                }
                throw SpeakerDiarizationRetryError.failed(
                    errorCode: Self.transcriptReplacementFailedCode
                )
            }
        }
    }

    private func isFailurePersisted(
        meetingID: UUID,
        errorCode: String
    ) -> Bool {
        guard let meeting = try? repository.meeting(id: meetingID) else {
            return false
        }
        return meeting.speakerProcessingState == .degraded
            && meeting.speakerProcessingErrorCode == errorCode
    }

    private static func transcriptDraft(
        _ transcript: TranscriptRecord
    ) -> TranscriptDraft {
        TranscriptDraft(
            startTime: transcript.startTime,
            endTime: transcript.endTime,
            text: transcript.text
        )
    }

    private static func nextSourceRevision(
        for transcripts: [TranscriptRecord]
    ) -> Int {
        let current = transcripts.map(\.sourceRevision).max() ?? 0
        return current == Int.max ? Int.max : current + 1
    }

    private static func nameEvidence(
        transcripts: [TranscriptRecord],
        displayNames: [String: String]
    ) -> [SpeakerNameEvidence] {
        displayNames.keys.sorted().compactMap { speakerID in
            guard let displayName = displayNames[speakerID] else {
                return nil
            }
            let intervals = transcripts.compactMap {
                transcript -> SpeakerNameEvidenceInterval? in
                guard transcript.speakerID == speakerID else { return nil }
                return SpeakerNameEvidenceInterval(
                    startTime: transcript.startTime,
                    endTime: transcript.endTime,
                    source: transcript.source
                )
            }
            guard !intervals.isEmpty else { return nil }
            return SpeakerNameEvidence(
                speakerID: speakerID,
                displayName: displayName,
                intervals: intervals
            )
        }
    }

    private static func errorCode(
        for error: SpeakerDiarizationRetryError
    ) -> String {
        switch error {
        case .sourceUnavailable:
            sourceUnavailableCode
        case .noFinalTranscript:
            transcriptUnavailableCode
        case let .failed(errorCode):
            errorCode
        case .operationInProgress, .invalidState:
            SpeakerAwareTranscriptFinalizer.diarizationFailedCode
        }
    }

}
