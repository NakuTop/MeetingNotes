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

@MainActor
final class SpeakerDiarizationRetryUseCase:
    MeetingSpeakerDiarizationRetrying {
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

    init(
        repository: MeetingRepository,
        sourceLoader: any MeetingTrackAudioSourceLoading,
        diarizer: any SpeakerDiarizing,
        operationGate: MeetingOperationGate,
        intervalAssigner: SpeakerIntervalAssigner = SpeakerIntervalAssigner(),
        assembler: SpeakerTranscriptAssembler = SpeakerTranscriptAssembler(),
        nameRemapper: SpeakerNameRemapper = SpeakerNameRemapper()
    ) {
        self.repository = repository
        self.sourceLoader = sourceLoader
        self.diarizer = diarizer
        self.operationGate = operationGate
        self.intervalAssigner = intervalAssigner
        self.assembler = assembler
        self.nameRemapper = nameRemapper
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
            guard !finalTranscripts.isEmpty else {
                throw SpeakerDiarizationRetryError.noFinalTranscript
            }
            let sourceRevision = Self.nextSourceRevision(
                for: finalTranscripts
            )
            let nameEvidence = Self.nameEvidence(
                transcripts: finalTranscripts,
                displayNames: meeting.speakerDisplayNames
            )
            let replacement: [AttributedTranscriptDraft]
            switch meeting.mode {
            case .offline:
                replacement = try await retryOffline(
                    meetingID: meetingID,
                    transcripts: finalTranscripts
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
                newDrafts: replacement
            )
            do {
                try repository.completeSpeakerDiarizationRetry(
                    meetingID: meetingID,
                    drafts: replacement,
                    sourceRevision: sourceRevision,
                    speakerDisplayNames: remappedNames
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
    ) async throws -> [AttributedTranscriptDraft] {
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
        guard tagged.count == transcripts.count,
              tagged.contains(where: { $0.1 == .system }) else {
            throw SpeakerDiarizationRetryError.sourceUnavailable
        }

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
