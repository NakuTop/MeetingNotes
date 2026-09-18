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
    func retry(meetingID: UUID, speakerCount: SpeakerCountConstraint) async throws
}

extension MeetingSpeakerDiarizationRetrying {
    func retry(meetingID: UUID, speakerCount: SpeakerCountConstraint) async throws {
        guard speakerCount == .automatic else { throw SpeakerDiarizationError.unsupportedSpeakerCount }
        try await retry(meetingID: meetingID)
    }
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
    static let speakerCountMismatchCode = "speaker_diarization_count_not_confirmed"

    private let repository: MeetingRepository
    private let sourceLoader: any MeetingTrackAudioSourceLoading
    private let diarizer: any SpeakerDiarizing
    private let operationGate: MeetingOperationGate
    private let intervalAssigner: SpeakerIntervalAssigner
    private let assembler: SpeakerTranscriptAssembler
    private let nameRemapper: SpeakerNameRemapper
    private let sourceReviewer: (any OnlineSpeakerSourceReviewing)?
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
            (any PreferredTranscriptionServiceProviding)? = nil,
        sourceReviewer: (any OnlineSpeakerSourceReviewing)? = nil
    ) {
        self.repository = repository
        self.sourceLoader = sourceLoader
        self.diarizer = diarizer
        self.operationGate = operationGate
        self.intervalAssigner = intervalAssigner
        self.assembler = assembler
        self.nameRemapper = nameRemapper
        self.sourceReviewer = sourceReviewer
        self.onlineRebuilder = onlineRebuilder
        self.transcriptionServiceProvider = transcriptionServiceProvider
    }

    func retry(meetingID: UUID) async throws {
        try await performRetry(meetingID: meetingID, speakerCount: nil)
    }

    func retry(meetingID: UUID, speakerCount: SpeakerCountConstraint) async throws {
        try await performRetry(meetingID: meetingID, speakerCount: speakerCount)
    }

    private func performRetry(meetingID: UUID, speakerCount: SpeakerCountConstraint?) async throws {
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
                meetingID: meetingID,
                speakerCount: speakerCount
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
            let requestedCount = meeting.speakerCountConstraint
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
                    drafts: try await reattributeMasterTranscripts(
                        meetingID: meetingID,
                        mode: .offline,
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
            let reviewed: [AttributedTranscriptDraft]
            if meeting.mode == .online, let sourceReviewer {
                reviewed = try await sourceReviewer.review(meetingID: meetingID, drafts: replacement.drafts)
            } else { reviewed = replacement.drafts }
            try Task.checkCancellation()
            let remappedNames = nameRemapper.remap(
                oldNamedSpeakers: nameEvidence,
                newDrafts: reviewed
            )
            do {
                try repository.completeSpeakerDiarizationRetry(
                    meetingID: meetingID,
                    drafts: reviewed,
                    sourceRevision: sourceRevision,
                    speakerDisplayNames: remappedNames,
                    degradationErrorCode: replacement.degradationErrorCode
                        ?? (requestedCount.accepts(observedCount: Set(replacement.drafts.compactMap(\.speakerID)).count)
                            ? nil : Self.speakerCountMismatchCode)
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

    private func reattributeMasterTranscripts(
        meetingID: UUID,
        mode: MeetingMode,
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
        let count = try repository.meeting(id: meetingID).speakerCountConstraint
        let drafts = transcripts.map(Self.transcriptDraft)
        let analysis = try await diarizer.analyze(source: source, speakerCount: count,
                                                 reviewSpans: SpeakerReviewSpan.measured(in: drafts))
        guard !analysis.intervals.isEmpty else {
            throw SpeakerDiarizationError.resultValidationFailed
        }
        let attributed = assembler.assemble(
            intervalAssigner.assign(
                drafts,
                intervals: analysis.intervals,
                speakerPrefix: mode == .online ? "speaker" : "room",
                source: mode == .online ? .mixed : .room,
                refinements: analysis.refinements
            )
        )
        guard mode == .online else { return attributed }
        // Retain proven physical-track provenance on legacy tagged rows, even
        // when a whole-meeting count calls for one global master analysis.
        let sources = Dictionary(grouping: transcripts) {
            TranscriptAttributionOrigin(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
        }
        return attributed.map { draft in
            guard let origin = draft.attributionOrigin, let records = sources[origin], records.count == 1,
                  let source = records.first?.source, source == .microphone || source == .system else { return draft }
            return AttributedTranscriptDraft(transcript: draft.transcript, speakerID: draft.speakerID, source: source,
                                             attributionStatus: draft.attributionStatus, attributionOrigin: origin,
                                             reviewHint: draft.reviewHint)
        }
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
        if try repository.meeting(id: meetingID).speakerCountConstraint == .automatic,
           tagged.count == transcripts.count,
           tagged.contains(where: { $0.1 == .system }) {
            return RetryReplacement(
                drafts: try await reattributeTaggedOnlineTranscripts(
                    meetingID: meetingID,
                    tagged: tagged
                ),
                degradationErrorCode: nil
            )
        }

        if !transcripts.isEmpty {
            // Untagged live transcripts were recognized from the master mix.
            // Speaker-only retry must preserve those words (and corrections),
            // not silently run hours of source-track Whisper decoding again.
            return RetryReplacement(
                drafts: try await reattributeMasterTranscripts(
                    meetingID: meetingID,
                    mode: .online,
                    transcripts: transcripts
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
            text: transcript.text,
            words: transcript.words
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
