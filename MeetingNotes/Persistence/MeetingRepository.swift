import Foundation
import SwiftData

enum MeetingRepositoryError: Error, Equatable, Sendable {
    case meetingNotFound(UUID)
    case invalidState(SpeakerProcessingState)
}

enum MeetingDocumentRepositoryError: Error, Equatable, Sendable {
    case missingDocument(MeetingDocumentKind)
    case existingDocumentRequiresGuardedSave(MeetingDocumentKind)
    case missingArchiveCheckpoint
    case invalidMetadataArchiveCheckpoint
    case invalidArchiveRun(MeetingDocumentKind)
    case invalidNotionPageSyncRun
    case staleDocumentRevision(
        MeetingDocumentKind,
        expected: Int,
        actual: Int
    )
    case manualEditProtected(MeetingDocumentKind)
    case staleMeetingContentRevision(expected: Int, actual: Int)
}

enum SpeakerNameRepositoryError: Error, Equatable, Sendable {
    case invalidDisplayName
    case speakerNotFound(String)
}

enum TranscriptCorrectionRepositoryError: Error, Equatable, Sendable {
    case correctionNotFound(UUID)
}

enum MeetingTimelineRepositoryError: Error, Equatable, Sendable {
    case noteNotFound(UUID)
    case screenshotNotFound(UUID)
    case invalidScreenshotPath
}

@MainActor
final class MeetingRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let contextSaver: @MainActor (ModelContext) throws -> Void
    private let detailedMinutesEncoder:
        (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes

    private static var schema: Schema {
        Schema([
            MeetingRecord.self,
            TranscriptRecord.self,
            TranscriptCorrectionRecord.self,
            SpeakerNameRecord.self,
            BookmarkRecord.self,
            MeetingNoteRecord.self,
            MeetingScreenshotRecord.self,
            SummaryRecord.self,
            DetailedMinutesRecord.self,
            ArchiveCheckpointRecord.self
        ])
    }

    init(
        container: ModelContainer,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        },
        detailedMinutesEncoder: @escaping
            (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes = {
                try DetailedMinutesRecord.encode($0)
            }
    ) {
        self.container = container
        context = ModelContext(container)
        self.contextSaver = contextSaver
        self.detailedMinutesEncoder = detailedMinutesEncoder
    }

    static func inMemory(
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        },
        detailedMinutesEncoder: @escaping
            (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes = {
                try DetailedMinutesRecord.encode($0)
            }
    ) throws -> MeetingRepository {
        let schema = Self.schema
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return MeetingRepository(
            container: container,
            contextSaver: contextSaver,
            detailedMinutesEncoder: detailedMinutesEncoder
        )
    }

    static func persistent() throws -> MeetingRepository {
        let schema = Self.schema
        let configuration = ModelConfiguration(schema: schema)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return MeetingRepository(container: container)
    }

    @discardableResult
    func createMeeting(
        id: UUID = UUID(),
        mode: MeetingMode,
        startedAt: Date,
        title: String = MeetingRecord.defaultTitle,
        audioManifestPath: String? = nil,
        speakerDiarizationRequested: Bool = false
    ) throws -> UUID {
        let meeting = MeetingRecord(
            id: id,
            title: title,
            mode: mode,
            state: .preparing,
            startedAt: startedAt,
            audioManifestPath: audioManifestPath,
            createdAt: startedAt,
            updatedAt: startedAt,
            speakerDiarizationRequested: speakerDiarizationRequested
        )
        context.insert(meeting)
        try saveContext()
        return meeting.id
    }

    func meetings() throws -> [MeetingRecord] {
        try context.fetch(FetchDescriptor<MeetingRecord>()).sorted(
            by: Self.meetingComesBefore
        )
    }

    func meeting(id: UUID) throws -> MeetingRecord {
        try meeting(id: id, in: context)
    }

    func transcripts(meetingID: UUID) throws -> [TranscriptRecord] {
        try meeting(id: meetingID).transcripts.sorted(
            by: Self.transcriptComesBefore
        )
    }

    func saveTranscriptCorrection(
        meetingID: UUID,
        transcriptIDs: [UUID],
        anchorStartTime: TimeInterval,
        anchorEndTime: TimeInterval,
        source: TranscriptAudioSource,
        originalText: String,
        replacementText: String,
        now: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let resolvedTarget = resolvedNewTranscriptCorrectionTarget(
            meeting: meeting,
            transcriptIDs: transcriptIDs,
            anchorStartTime: anchorStartTime,
            anchorEndTime: anchorEndTime,
            source: source
        )
        let resolvedTranscriptIDs = resolvedTarget?.transcriptIDs
            ?? transcriptIDs
        let resolvedAnchorStartTime = resolvedTarget?.startTime
            ?? anchorStartTime
        let resolvedAnchorEndTime = resolvedTarget?.endTime
            ?? anchorEndTime
        let resolvedSource = resolvedTarget?.source ?? source
        let targetIDs = Set(resolvedTranscriptIDs)
        if !targetIDs.isEmpty,
           let correction = meeting.transcriptCorrections.first(where: {
               $0.source == resolvedSource
                   && Set($0.transcriptIDs) == targetIDs
           }) {
            let isUnchanged = correction.anchorStartTime
                    == resolvedAnchorStartTime
                && correction.anchorEndTime == resolvedAnchorEndTime
                && correction.replacementText == replacementText
            guard !isUnchanged else {
                return
            }
            let previousUpdatedAt = meeting.updatedAt
            let contentSnapshot = try beginContentMutation(for: meeting)
            let previousAnchorStartTime = correction.anchorStartTime
            let previousAnchorEndTime = correction.anchorEndTime
            let previousReplacementText = correction.replacementText
            let previousTranscriptIDs = correction.transcriptIDs
            let previousCorrectionUpdatedAt = correction.updatedAt
            correction.anchorStartTime = resolvedAnchorStartTime
            correction.anchorEndTime = resolvedAnchorEndTime
            correction.replacementText = replacementText
            correction.transcriptIDs = resolvedTranscriptIDs
            correction.updatedAt = now
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                correction.anchorStartTime = previousAnchorStartTime
                correction.anchorEndTime = previousAnchorEndTime
                correction.replacementText = previousReplacementText
                correction.transcriptIDs = previousTranscriptIDs
                correction.updatedAt = previousCorrectionUpdatedAt
                meeting.updatedAt = previousUpdatedAt
                contentSnapshot.restore(meeting)
                throw error
            }
            return
        }

        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let correction = TranscriptCorrectionRecord(
            anchorStartTime: resolvedAnchorStartTime,
            anchorEndTime: resolvedAnchorEndTime,
            source: resolvedSource,
            originalText: originalText,
            replacementText: replacementText,
            transcriptIDs: resolvedTranscriptIDs,
            createdAt: now,
            updatedAt: now,
            meeting: meeting
        )
        context.insert(correction)
        meeting.transcriptCorrections.append(correction)
        meeting.updatedAt = now
        do {
            try saveContext()
        } catch {
            meeting.transcriptCorrections.removeAll { $0 === correction }
            context.delete(correction)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func updateTranscriptCorrection(
        meetingID: UUID,
        correctionID: UUID,
        replacementText: String,
        now: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let correction = meeting.transcriptCorrections.first(where: {
            $0.id == correctionID
        }) else {
            throw TranscriptCorrectionRepositoryError.correctionNotFound(
                correctionID
            )
        }
        guard correction.replacementText != replacementText else { return }

        let previousReplacementText = correction.replacementText
        let previousCorrectionUpdatedAt = correction.updatedAt
        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        correction.replacementText = replacementText
        correction.updatedAt = now
        meeting.updatedAt = now
        do {
            try saveContext()
        } catch {
            correction.replacementText = previousReplacementText
            correction.updatedAt = previousCorrectionUpdatedAt
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func reconciledTranscriptCorrectionTarget(
        meetingID: UUID,
        transcriptIDs: [UUID],
        anchorStartTime: TimeInterval,
        anchorEndTime: TimeInterval,
        source: TranscriptAudioSource
    ) throws -> CanonicalTranscriptEntry? {
        let meeting = try meeting(id: meetingID)
        guard let resolved = resolvedNewTranscriptCorrectionTarget(
            meeting: meeting,
            transcriptIDs: transcriptIDs,
            anchorStartTime: anchorStartTime,
            anchorEndTime: anchorEndTime,
            source: source
        ) else {
            return nil
        }
        let resolvedIDs = Set(resolved.transcriptIDs)
        let canonical = TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts,
            corrections: meeting.transcriptCorrections
        )
        let candidates = canonical.filter {
            !$0.isManuallyEdited
                && Set($0.transcriptIDs) == resolvedIDs
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    func canonicalTranscripts(
        meetingID: UUID
    ) throws -> [CanonicalTranscriptEntry] {
        let meeting = try meeting(id: meetingID)
        return TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts,
            corrections: meeting.transcriptCorrections
        )
    }

    private func resolvedNewTranscriptCorrectionTarget(
        meeting: MeetingRecord,
        transcriptIDs: [UUID],
        anchorStartTime: TimeInterval,
        anchorEndTime: TimeInterval,
        source: TranscriptAudioSource
    ) -> CanonicalTranscriptEntry? {
        let currentTranscriptIDs = Set(meeting.transcripts.map(\.id))
        guard !transcriptIDs.isEmpty,
              !transcriptIDs.allSatisfy(currentTranscriptIDs.contains) else {
            return nil
        }
        let probeID = UUID()
        let probe = TranscriptCorrectionRecord(
            id: probeID,
            anchorStartTime: anchorStartTime,
            anchorEndTime: anchorEndTime,
            source: source,
            originalText: "",
            replacementText: "",
            transcriptIDs: transcriptIDs
        )
        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts,
            corrections: meeting.transcriptCorrections + [probe]
        )
        guard let target = resolved.first(where: { $0.id == probeID }),
              !target.transcriptIDs.isEmpty,
              target.transcriptIDs.allSatisfy(
                  currentTranscriptIDs.contains
              ) else {
            return nil
        }
        return target
    }

    func previewExactReplacement(
        meetingID: UUID,
        old: String,
        new: String
    ) throws -> MeetingExactReplacementPreview {
        try MeetingExactTextReplacement.validate(old: old, new: new)
        let meeting = try meeting(id: meetingID)
        return try exactReplacementPlan(
            meeting: meeting,
            old: old,
            new: new
        ).preview
    }

    func applyExactReplacement(
        _ confirmedPreview: MeetingExactReplacementPreview,
        now: Date = .now
    ) throws -> MeetingExactReplacementPreview {
        try MeetingExactTextReplacement.validate(
            old: confirmedPreview.searchText,
            new: confirmedPreview.replacementText
        )
        let meeting = try meeting(id: confirmedPreview.meetingID)
        guard meeting.contentRevision
            == confirmedPreview.observedContentRevision else {
            throw MeetingExactReplacementError.stalePreview(
                expectedContentRevision:
                    confirmedPreview.observedContentRevision,
                actualContentRevision: meeting.contentRevision
            )
        }
        let plan = try exactReplacementPlan(
            meeting: meeting,
            old: confirmedPreview.searchText,
            new: confirmedPreview.replacementText
        )
        guard plan.preview == confirmedPreview else {
            throw MeetingExactReplacementError.stalePreview(
                expectedContentRevision:
                    confirmedPreview.observedContentRevision,
                actualContentRevision: meeting.contentRevision
            )
        }
        guard plan.preview.totalMatches > 0 else {
            return plan.preview
        }

        let nextSummaryRevision = try plan.summary.map {
            try MeetingDocumentRevision.next(after: $0.record.contentRevision)
        }
        let nextMinutesRevision = try plan.detailedMinutes.map {
            try MeetingDocumentRevision.next(after: $0.record.contentRevision)
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let correctionSnapshots = plan.transcripts.compactMap {
            $0.correction.map(ExactTranscriptCorrectionSnapshot.init)
        }
        let speakerSnapshots = plan.speakers.map {
            SpeakerNameSnapshot($0.record)
        }
        let summarySnapshot = plan.summary.map {
            SummarySnapshot($0.record)
        }
        let minutesSnapshot = plan.detailedMinutes.map {
            DetailedMinutesSnapshot($0.record)
        }
        var insertedCorrections: [TranscriptCorrectionRecord] = []

        for replacement in plan.transcripts {
            if let correction = replacement.correction {
                correction.replacementText = replacement.replacementText
                correction.updatedAt = now
            } else {
                let entry = replacement.entry
                let correction = TranscriptCorrectionRecord(
                    anchorStartTime: entry.startTime,
                    anchorEndTime: entry.endTime,
                    source: entry.source,
                    originalText: entry.text,
                    replacementText: replacement.replacementText,
                    transcriptIDs: entry.transcriptIDs,
                    createdAt: now,
                    updatedAt: now,
                    meeting: meeting
                )
                context.insert(correction)
                meeting.transcriptCorrections.append(correction)
                insertedCorrections.append(correction)
            }
        }
        for replacement in plan.speakers {
            replacement.record.displayName = replacement.displayName
            replacement.record.updatedAt = now
        }
        if let replacement = plan.summary,
           let nextSummaryRevision {
            let summary = replacement.record
            if let overview = replacement.overview {
                summary.overview = overview
            }
            if let keyPointsData = replacement.keyPointsData {
                summary.keyPointsData = keyPointsData
            }
            if let decisionsData = replacement.decisionsData {
                summary.decisionsData = decisionsData
            }
            if let actionItemsData = replacement.actionItemsData {
                summary.actionItemsData = actionItemsData
            }
            if let bookmarkInsightsData = replacement.bookmarkInsightsData {
                summary.bookmarkInsightsData = bookmarkInsightsData
            }
            summary.contentRevision = nextSummaryRevision
            summary.isManuallyEdited = true
            summary.archiveState = .localOnly
            summary.archivedContentRevision = nil
            summary.lastArchiveErrorCode = nil
        }
        if let replacement = plan.detailedMinutes,
           let nextMinutesRevision {
            let minutes = replacement.record
            if let overview = replacement.overview {
                minutes.overview = overview
            }
            if let sectionsData = replacement.sectionsData {
                minutes.sectionsData = sectionsData
            }
            if let decisionsData = replacement.decisionsData {
                minutes.decisionsData = decisionsData
            }
            if let actionItemsData = replacement.actionItemsData {
                minutes.actionItemsData = actionItemsData
            }
            if let openQuestionsData = replacement.openQuestionsData {
                minutes.openQuestionsData = openQuestionsData
            }
            minutes.contentRevision = nextMinutesRevision
            minutes.isManuallyEdited = true
            minutes.archiveState = .localOnly
            minutes.archivedContentRevision = nil
            minutes.lastArchiveErrorCode = nil
        }
        meeting.updatedAt = now

        do {
            try saveContext()
        } catch {
            for (replacement, snapshot) in zip(
                plan.transcripts.compactMap(\.correction),
                correctionSnapshots
            ) {
                snapshot.restore(replacement)
            }
            for correction in insertedCorrections {
                meeting.transcriptCorrections.removeAll { $0 === correction }
                context.delete(correction)
            }
            for (replacement, snapshot) in zip(plan.speakers, speakerSnapshots) {
                snapshot.restore(replacement.record)
            }
            if let summary = plan.summary?.record, let summarySnapshot {
                summarySnapshot.restore(summary)
            }
            if let minutes = plan.detailedMinutes?.record, let minutesSnapshot {
                minutesSnapshot.restore(minutes)
            }
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
        return plan.preview
    }

    private func exactReplacementPlan(
        meeting: MeetingRecord,
        old: String,
        new: String
    ) throws -> ExactMeetingReplacementPlan {
        let canonicalTranscripts = TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts,
            corrections: meeting.transcriptCorrections
        )
        let correctionsByID = Dictionary(
            meeting.transcriptCorrections.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var transcriptMatches = 0
        var transcriptReplacements: [ExactTranscriptReplacement] = []
        for entry in canonicalTranscripts {
            let result = MeetingExactTextReplacement.replacing(
                entry.text,
                old: old,
                new: new
            )
            transcriptMatches = MeetingExactTextReplacement.saturatingAdd(
                transcriptMatches,
                result.matches
            )
            guard result.matches > 0 else { continue }
            transcriptReplacements.append(
                ExactTranscriptReplacement(
                    entry: entry,
                    correction: entry.isManuallyEdited
                        ? correctionsByID[entry.id]
                        : nil,
                    replacementText: result.value
                )
            )
        }

        var speakerMatches = 0
        var speakerReplacements: [ExactSpeakerReplacement] = []
        for record in meeting.speakerNames {
            let result = MeetingExactTextReplacement.replacing(
                record.displayName,
                old: old,
                new: new
            )
            speakerMatches = MeetingExactTextReplacement.saturatingAdd(
                speakerMatches,
                result.matches
            )
            guard result.matches > 0 else { continue }
            let normalizedDisplayName = try Self.normalizedSpeakerDisplayName(
                result.value
            )
            speakerReplacements.append(
                ExactSpeakerReplacement(
                    record: record,
                    displayName: normalizedDisplayName
                )
            )
        }

        let summaryReplacement = try meeting.summary.flatMap {
            try exactSummaryReplacement(record: $0, old: old, new: new)
        }
        let minutesReplacement = try meeting.detailedMinutes.flatMap {
            try exactDetailedMinutesReplacement(
                record: $0,
                old: old,
                new: new
            )
        }
        let preview = MeetingExactReplacementPreview(
            meetingID: meeting.id,
            observedContentRevision: meeting.contentRevision,
            searchText: old,
            replacementText: new,
            transcriptMatches: transcriptMatches,
            speakerMatches: speakerMatches,
            summaryMatches: summaryReplacement?.matches ?? 0,
            detailedMinutesMatches: minutesReplacement?.matches ?? 0
        )
        return ExactMeetingReplacementPlan(
            preview: preview,
            transcripts: transcriptReplacements,
            speakers: speakerReplacements,
            summary: summaryReplacement,
            detailedMinutes: minutesReplacement
        )
    }

    private func exactSummaryReplacement(
        record: SummaryRecord,
        old: String,
        new: String
    ) throws -> ExactSummaryReplacement? {
        let overviewResult = MeetingExactTextReplacement.replacing(
            record.overview,
            old: old,
            new: new
        )
        let keyPoints = try exactEncodedReplacement(
            record.keyPointsData,
            as: [String].self,
            field: "summary.keyPoints",
            old: old,
            new: new
        ) { values, matches in
            exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let decisions = try exactEncodedReplacement(
            record.decisionsData,
            as: [String].self,
            field: "summary.decisions",
            old: old,
            new: new
        ) { values, matches in
            exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let actionItems = try exactSummaryActionItemsReplacement(
            record.actionItemsData,
            field: "summary.actionItems",
            old: old,
            new: new
        )
        let bookmarkInsights = try exactEncodedReplacement(
            record.bookmarkInsightsData,
            as: [String].self,
            field: "summary.bookmarkInsights",
            old: old,
            new: new
        ) { values, matches in
            exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let matches = [
            overviewResult.matches,
            keyPoints.matches,
            decisions.matches,
            actionItems.matches,
            bookmarkInsights.matches
        ].reduce(0, MeetingExactTextReplacement.saturatingAdd)
        guard matches > 0 else { return nil }
        return ExactSummaryReplacement(
            record: record,
            overview: overviewResult.matches > 0
                ? overviewResult.value
                : nil,
            keyPointsData: keyPoints.data,
            decisionsData: decisions.data,
            actionItemsData: actionItems.data,
            bookmarkInsightsData: bookmarkInsights.data,
            matches: matches
        )
    }

    private func exactDetailedMinutesReplacement(
        record: DetailedMinutesRecord,
        old: String,
        new: String
    ) throws -> ExactDetailedMinutesReplacement? {
        let overviewResult = MeetingExactTextReplacement.replacing(
            record.overview,
            old: old,
            new: new
        )
        let sections = try exactEncodedReplacement(
            record.sectionsData,
            as: [DetailedMinutesSection].self,
            field: "detailedMinutes.sections",
            old: old,
            new: new
        ) { sections, matches in
            sections.map { section in
                DetailedMinutesSection(
                    title: exactReplacement(
                        section.title,
                        old: old,
                        new: new,
                        matches: &matches
                    ),
                    timeRange: section.timeRange,
                    speakers: exactReplacements(
                        section.speakers,
                        old: old,
                        new: new,
                        matches: &matches
                    ),
                    content: exactReplacement(
                        section.content,
                        old: old,
                        new: new,
                        matches: &matches
                    )
                )
            }
        }
        let decisions = try exactEncodedReplacement(
            record.decisionsData,
            as: [String].self,
            field: "detailedMinutes.decisions",
            old: old,
            new: new
        ) { values, matches in
            exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let actionItems = try exactEncodedReplacement(
            record.actionItemsData,
            as: [ActionItem].self,
            field: "detailedMinutes.actionItems",
            old: old,
            new: new
        ) { items, matches in
            exactActionItemReplacements(
                items,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let openQuestions = try exactEncodedReplacement(
            record.openQuestionsData,
            as: [String].self,
            field: "detailedMinutes.openQuestions",
            old: old,
            new: new
        ) { values, matches in
            exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
        }
        let matches = [
            overviewResult.matches,
            sections.matches,
            decisions.matches,
            actionItems.matches,
            openQuestions.matches
        ].reduce(0, MeetingExactTextReplacement.saturatingAdd)
        guard matches > 0 else { return nil }
        return ExactDetailedMinutesReplacement(
            record: record,
            overview: overviewResult.matches > 0
                ? overviewResult.value
                : nil,
            sectionsData: sections.data,
            decisionsData: decisions.data,
            actionItemsData: actionItems.data,
            openQuestionsData: openQuestions.data,
            matches: matches
        )
    }

    private func exactSummaryActionItemsReplacement(
        _ data: Data,
        field: String,
        old: String,
        new: String
    ) throws -> ExactStructuredDataReplacement {
        let candidateMatches = try structuredStringMatchCount(
            in: data,
            old: old,
            field: field
        )
        guard candidateMatches > 0 else {
            return ExactStructuredDataReplacement(data: nil, matches: 0)
        }

        let decoder = JSONDecoder()
        if let values = try? decoder.decode([ActionItem].self, from: data) {
            var matches = 0
            let replacements = exactActionItemReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
            return try encodedStructuredReplacement(
                replacements,
                matches: matches,
                field: field
            )
        }
        if let values = try? decoder.decode([String].self, from: data) {
            var matches = 0
            let replacements = exactReplacements(
                values,
                old: old,
                new: new,
                matches: &matches
            )
            return try encodedStructuredReplacement(
                replacements,
                matches: matches,
                field: field
            )
        }
        throw MeetingExactReplacementError.invalidStructuredField(field)
    }

    private func exactEncodedReplacement<Value: Codable>(
        _ data: Data,
        as type: Value.Type,
        field: String,
        old: String,
        new: String,
        transform: (Value, inout Int) -> Value
    ) throws -> ExactStructuredDataReplacement {
        let candidateMatches = try structuredStringMatchCount(
            in: data,
            old: old,
            field: field
        )
        guard candidateMatches > 0 else {
            return ExactStructuredDataReplacement(data: nil, matches: 0)
        }

        let decoded: Value
        do {
            decoded = try JSONDecoder().decode(type, from: data)
        } catch {
            throw MeetingExactReplacementError.invalidStructuredField(field)
        }
        var matches = 0
        let replacement = transform(decoded, &matches)
        return try encodedStructuredReplacement(
            replacement,
            matches: matches,
            field: field
        )
    }

    private func encodedStructuredReplacement<Value: Encodable>(
        _ value: Value,
        matches: Int,
        field: String
    ) throws -> ExactStructuredDataReplacement {
        guard matches > 0 else {
            return ExactStructuredDataReplacement(data: nil, matches: 0)
        }
        do {
            return ExactStructuredDataReplacement(
                data: try JSONEncoder().encode(value),
                matches: matches
            )
        } catch {
            throw MeetingExactReplacementError.invalidStructuredField(field)
        }
    }

    private func structuredStringMatchCount(
        in data: Data,
        old: String,
        field: String
    ) throws -> Int {
        do {
            let value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
            return structuredStringMatchCount(in: value, old: old)
        } catch {
            let rawValue = String(decoding: data, as: UTF8.self)
            let rawMatches = MeetingExactTextReplacement.replacing(
                rawValue,
                old: old,
                new: old
            ).matches
            guard rawMatches == 0 else {
                throw MeetingExactReplacementError.invalidStructuredField(field)
            }
            return 0
        }
    }

    private func structuredStringMatchCount(
        in value: Any,
        old: String
    ) -> Int {
        if let string = value as? String {
            return MeetingExactTextReplacement.replacing(
                string,
                old: old,
                new: old
            ).matches
        }
        if let values = value as? [Any] {
            return values.reduce(0) { count, value in
                MeetingExactTextReplacement.saturatingAdd(
                    count,
                    structuredStringMatchCount(in: value, old: old)
                )
            }
        }
        if let values = value as? [String: Any] {
            return values.values.reduce(0) { count, value in
                MeetingExactTextReplacement.saturatingAdd(
                    count,
                    structuredStringMatchCount(in: value, old: old)
                )
            }
        }
        return 0
    }

    private func exactActionItemReplacements(
        _ values: [ActionItem],
        old: String,
        new: String,
        matches: inout Int
    ) -> [ActionItem] {
        values.map { item in
            ActionItem(
                task: exactReplacement(
                    item.task,
                    old: old,
                    new: new,
                    matches: &matches
                ),
                owner: item.owner.map {
                    exactReplacement(
                        $0,
                        old: old,
                        new: new,
                        matches: &matches
                    )
                },
                dueDate: item.dueDate
            )
        }
    }

    private func exactReplacements(
        _ values: [String],
        old: String,
        new: String,
        matches: inout Int
    ) -> [String] {
        values.map {
            exactReplacement(
                $0,
                old: old,
                new: new,
                matches: &matches
            )
        }
    }

    private func exactReplacement(
        _ value: String,
        old: String,
        new: String,
        matches: inout Int
    ) -> String {
        let result = MeetingExactTextReplacement.replacing(
            value,
            old: old,
            new: new
        )
        matches = MeetingExactTextReplacement.saturatingAdd(
            matches,
            result.matches
        )
        return result.value
    }

    private func meeting(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> MeetingRecord {
        var descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        guard let meeting = try modelContext.fetch(descriptor).first else {
            throw MeetingRepositoryError.meetingNotFound(id)
        }
        return meeting
    }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        let meeting = try meeting(id: meetingID)
        meeting.pinnedAt = pinnedAt
        meeting.updatedAt = .now
        try saveContext()
    }

    func updateTitle(meetingID: UUID, title: String) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.title != title else { return }
        let previousTitle = meeting.title
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        meeting.title = title
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.title = previousTitle
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func appendTranscript(
        meetingID: UUID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isFinal: Bool = true,
        speakerID: String? = nil,
        sourceRevision: Int = 0
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let transcript = TranscriptRecord(
            startTime: start,
            endTime: end,
            text: text,
            isFinal: isFinal,
            speakerID: speakerID,
            sourceRevision: sourceRevision,
            meeting: meeting
        )
        context.insert(transcript)
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.transcripts.removeAll { $0 === transcript }
            context.delete(transcript)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func replaceTranscripts(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int
    ) throws {
        let replacementContext = ModelContext(container)
        replacementContext.autosaveEnabled = false
        let meeting = try meeting(
            id: meetingID,
            in: replacementContext
        )
        let previousTranscripts = meeting.transcripts
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let replacements = drafts.enumerated().map { sequenceIndex, draft in
            TranscriptRecord(
                startTime: draft.transcript.startTime,
                endTime: draft.transcript.endTime,
                text: draft.transcript.text,
                isFinal: true,
                speakerID: draft.speakerID,
                sourceRawValue: draft.source.rawValue,
                sourceRevision: sourceRevision,
                sequenceIndex: sequenceIndex
            )
        }

        let correctionRebinds = Self.rebindTranscriptCorrections(
            meeting.transcriptCorrections,
            to: replacements
        )

        replacements.forEach(replacementContext.insert)
        meeting.transcripts = replacements
        meeting.updatedAt = .now
        previousTranscripts.forEach(replacementContext.delete)
        do {
            try contextSaver(replacementContext)
            synchronizeRegisteredCorrections(correctionRebinds)
        } catch {
            replacementContext.rollback()
            correctionRebinds.forEach { $0.restore() }
            meeting.transcripts = previousTranscripts
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func speakerDisplayNames(meetingID: UUID) throws -> [String: String] {
        try meeting(id: meetingID).speakerDisplayNames
    }

    func setSpeakerDisplayName(
        meetingID: UUID,
        speakerID: String,
        displayName: String,
        now: Date = .now
    ) throws {
        let normalizedName = try Self.normalizedSpeakerDisplayName(displayName)

        let meeting = try meeting(id: meetingID)
        let matchingTranscripts = meeting.transcripts.filter {
            $0.speakerID == speakerID
        }
        guard let evidenceStartTime = matchingTranscripts
            .map(\.startTime)
            .min(),
              let evidenceEndTime = matchingTranscripts
            .map(\.endTime)
            .max() else {
            throw SpeakerNameRepositoryError.speakerNotFound(speakerID)
        }

        let existingRecord = meeting.speakerNames.first(where: {
            $0.speakerID == speakerID
        })
        if existingRecord?.displayName == normalizedName {
            return
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        if let record = existingRecord {
            let previous = SpeakerNameSnapshot(record)
            record.displayName = normalizedName
            record.evidenceStartTime = evidenceStartTime
            record.evidenceEndTime = evidenceEndTime
            record.updatedAt = now
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                previous.restore(record)
                meeting.updatedAt = previousMeetingUpdatedAt
                contentSnapshot.restore(meeting)
                throw error
            }
        } else {
            let record = SpeakerNameRecord(
                speakerID: speakerID,
                displayName: normalizedName,
                evidenceStartTime: evidenceStartTime,
                evidenceEndTime: evidenceEndTime,
                createdAt: now,
                updatedAt: now,
                meeting: meeting
            )
            context.insert(record)
            meeting.speakerNames.append(record)
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                meeting.speakerNames.removeAll { $0 === record }
                context.delete(record)
                meeting.updatedAt = previousMeetingUpdatedAt
                contentSnapshot.restore(meeting)
                throw error
            }
        }
    }

    private static func normalizedSpeakerDisplayName(
        _ displayName: String
    ) throws -> String {
        guard let normalizedName = AppSettingsStore.normalizedSpeakerNames(
            [displayName]
        ).first else {
            throw SpeakerNameRepositoryError.invalidDisplayName
        }
        return normalizedName
    }

    func clearSpeakerDisplayName(
        meetingID: UUID,
        speakerID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let matches = meeting.speakerNames.filter {
            $0.speakerID == speakerID
        }
        guard !matches.isEmpty else { return }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let snapshots = matches.map(SpeakerNameSnapshot.init)
        meeting.speakerNames.removeAll { $0.speakerID == speakerID }
        matches.forEach(context.delete)
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            for (record, snapshot) in zip(matches, snapshots) {
                context.insert(record)
                snapshot.restore(record)
                record.meeting = meeting
                meeting.speakerNames.append(record)
            }
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func appendBookmark(
        meetingID: UUID,
        timestamp: TimeInterval,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let bookmark = BookmarkRecord(
            timestamp: timestamp,
            createdAt: createdAt,
            meeting: meeting
        )
        context.insert(bookmark)
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.bookmarks.removeAll { $0 === bookmark }
            context.delete(bookmark)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func notes(meetingID: UUID) throws -> [MeetingNoteRecord] {
        try meeting(id: meetingID).notes.sorted(by: Self.noteComesBefore)
    }

    func upsertNote(
        meetingID: UUID,
        id: UUID,
        timestamp: TimeInterval,
        text: String,
        sequenceIndex: Int,
        now: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)

        if let note = meeting.notes.first(where: { $0.id == id }) {
            guard note.text != text else { return }
            let previousText = note.text
            let previousUpdatedAt = note.updatedAt
            let previousMeetingUpdatedAt = meeting.updatedAt
            let contentSnapshot = try beginContentMutation(for: meeting)
            note.text = text
            note.updatedAt = now
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                note.text = previousText
                note.updatedAt = previousUpdatedAt
                meeting.updatedAt = previousMeetingUpdatedAt
                contentSnapshot.restore(meeting)
                throw error
            }
            return
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let note = MeetingNoteRecord(
            id: id,
            timestamp: Self.sanitizedTimelineTimestamp(timestamp),
            text: text,
            createdAt: now,
            updatedAt: now,
            sequenceIndex: max(0, sequenceIndex),
            meeting: meeting
        )
        context.insert(note)
        meeting.notes.append(note)
        meeting.updatedAt = now
        do {
            try saveContext()
        } catch {
            meeting.notes.removeAll { $0 === note }
            context.delete(note)
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func deleteNote(
        meetingID: UUID,
        id: UUID,
        now: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let note = meeting.notes.first(where: { $0.id == id }) else {
            throw MeetingTimelineRepositoryError.noteNotFound(id)
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let noteSnapshot = MeetingNoteSnapshot(note)
        meeting.notes.removeAll { $0.id == id }
        context.delete(note)
        meeting.updatedAt = now
        do {
            try saveContext()
        } catch {
            context.insert(note)
            noteSnapshot.restore(note)
            note.meeting = meeting
            meeting.notes.append(note)
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func screenshots(meetingID: UUID) throws -> [MeetingScreenshotRecord] {
        try meeting(id: meetingID).screenshots.sorted(
            by: Self.screenshotComesBefore
        )
    }

    func appendScreenshot(
        meetingID: UUID,
        id: UUID,
        timestamp: TimeInterval,
        relativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sequenceIndex: Int,
        createdAt: Date = .now
    ) throws {
        guard Self.isValidScreenshotRelativePath(relativePath) else {
            throw MeetingTimelineRepositoryError.invalidScreenshotPath
        }

        let meeting = try meeting(id: meetingID)
        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let screenshot = MeetingScreenshotRecord(
            id: id,
            timestamp: Self.sanitizedTimelineTimestamp(timestamp),
            relativePath: relativePath,
            pixelWidth: max(0, pixelWidth),
            pixelHeight: max(0, pixelHeight),
            byteCount: max(0, byteCount),
            createdAt: createdAt,
            sequenceIndex: max(0, sequenceIndex),
            meeting: meeting
        )
        context.insert(screenshot)
        meeting.screenshots.append(screenshot)
        meeting.updatedAt = createdAt
        do {
            try saveContext()
        } catch {
            meeting.screenshots.removeAll { $0 === screenshot }
            context.delete(screenshot)
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func deleteScreenshot(
        meetingID: UUID,
        id: UUID,
        now: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let screenshot = meeting.screenshots.first(where: {
            $0.id == id
        }) else {
            throw MeetingTimelineRepositoryError.screenshotNotFound(id)
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let screenshotSnapshot = MeetingScreenshotSnapshot(screenshot)
        meeting.screenshots.removeAll { $0.id == id }
        context.delete(screenshot)
        meeting.updatedAt = now
        do {
            try saveContext()
        } catch {
            context.insert(screenshot)
            screenshotSnapshot.restore(screenshot)
            screenshot.meeting = meeting
            meeting.screenshots.append(screenshot)
            meeting.updatedAt = previousMeetingUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func saveSummary(
        meetingID: UUID,
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [String],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now
    ) throws {
        try saveSummary(
            meetingID: meetingID,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            structuredActionItems: actionItems.map {
                ActionItem(task: $0, owner: nil, dueDate: nil)
            },
            bookmarkInsights: bookmarkInsights,
            model: model,
            createdAt: createdAt
        )
    }

    func saveSummary(
        meetingID: UUID,
        overview: String,
        keyPoints: [String],
        decisions: [String],
        structuredActionItems: [ActionItem],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.summary == nil else {
            throw MeetingDocumentRepositoryError
                .existingDocumentRequiresGuardedSave(.summary)
        }
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)

        let summary = SummaryRecord(
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: structuredActionItems,
            bookmarkInsights: bookmarkInsights,
            model: model,
            createdAt: createdAt,
            meeting: meeting
        )
        context.insert(summary)
        meeting.summary = summary
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.summary = nil
            context.delete(summary)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func saveDetailedMinutes(
        meetingID: UUID,
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.detailedMinutes == nil else {
            throw MeetingDocumentRepositoryError
                .existingDocumentRequiresGuardedSave(.detailedMinutes)
        }
        let encoded = try detailedMinutesEncoder(generated)
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)

        let minutes = DetailedMinutesRecord(
            overview: generated.overview,
            sectionsData: encoded.sections,
            decisionsData: encoded.decisions,
            actionItemsData: encoded.actionItems,
            openQuestionsData: encoded.openQuestions,
            model: model,
            promptVersion: promptVersion,
            createdAt: createdAt,
            contentRevision: 1,
            meeting: meeting
        )
        context.insert(minutes)
        meeting.detailedMinutes = minutes
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.detailedMinutes = nil
            context.delete(minutes)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func updateSummaryManually(
        meetingID: UUID,
        value: GeneratedMeetingSummary
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let summary = meeting.summary else {
            throw MeetingDocumentRepositoryError.missingDocument(.summary)
        }
        let previousSummary = SummarySnapshot(summary)
        let previousTitle = meeting.title
        let previousSuggestedTitle = meeting.suggestedTitle
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)

        do {
            try summary.update(
                overview: value.overview,
                keyPoints: value.keyPoints,
                decisions: value.decisions,
                actionItems: value.actionItems,
                bookmarkInsights: value.bookmarkInsights,
                model: summary.model,
                createdAt: summary.createdAt
            )
        } catch {
            contentSnapshot.restore(meeting)
            throw error
        }
        summary.isManuallyEdited = true
        let suggestedTitle = value.suggestedTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !suggestedTitle.isEmpty {
            meeting.suggestedTitle = suggestedTitle
            if meeting.title == MeetingRecord.defaultTitle {
                meeting.title = suggestedTitle
            }
        }
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            previousSummary.restore(summary)
            meeting.title = previousTitle
            meeting.suggestedTitle = previousSuggestedTitle
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func updateDetailedMinutesManually(
        meetingID: UUID,
        value: GeneratedDetailedMinutes
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let minutes = meeting.detailedMinutes else {
            throw MeetingDocumentRepositoryError.missingDocument(
                .detailedMinutes
            )
        }
        let encoded = try detailedMinutesEncoder(value)
        let nextDocumentRevision = try MeetingDocumentRevision.next(
            after: minutes.contentRevision
        )
        let previous = DetailedMinutesSnapshot(minutes)
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)

        minutes.overview = value.overview
        minutes.sectionsData = encoded.sections
        minutes.decisionsData = encoded.decisions
        minutes.actionItemsData = encoded.actionItems
        minutes.openQuestionsData = encoded.openQuestions
        minutes.contentRevision = nextDocumentRevision
        minutes.isManuallyEdited = true
        minutes.archiveState = .localOnly
        minutes.archivedContentRevision = nil
        minutes.lastArchiveErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            previous.restore(minutes)
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func saveGeneratedSummary(
        meetingID: UUID,
        generated: GeneratedMeetingSummary,
        model: String,
        createdAt: Date = .now
    ) throws {
        let observedMeetingContentRevision = try meeting(
            id: meetingID
        ).contentRevision
        try saveGeneratedSummary(
            meetingID: meetingID,
            generated: generated,
            model: model,
            observedMeetingContentRevision: observedMeetingContentRevision,
            replacingManualEdits: false,
            createdAt: createdAt
        )
    }

    func saveGeneratedSummary(
        meetingID: UUID,
        generated: GeneratedMeetingSummary,
        model: String,
        observedMeetingContentRevision: Int,
        replacingManualEdits: Bool = false,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let actualContentRevision = meeting.contentRevision
        guard observedMeetingContentRevision == actualContentRevision else {
            throw MeetingDocumentRepositoryError
                .staleMeetingContentRevision(
                    expected: observedMeetingContentRevision,
                    actual: actualContentRevision
                )
        }
        if meeting.summary?.isManuallyEdited == true,
           !replacingManualEdits {
            throw MeetingDocumentRepositoryError
                .manualEditProtected(.summary)
        }
        let previousStateRawValue = meeting.stateRawValue
        let previousTitle = meeting.title
        let previousSuggestedTitle = meeting.suggestedTitle
        let previousUpdatedAt = meeting.updatedAt
        let existingSummary = meeting.summary
        let existingSnapshot = existingSummary.map(SummarySnapshot.init)
        let contentSnapshot = try beginContentMutation(for: meeting)

        do {
            if let summary = existingSummary {
                try summary.update(
                    overview: generated.overview,
                    keyPoints: generated.keyPoints,
                    decisions: generated.decisions,
                    actionItems: generated.actionItems,
                    bookmarkInsights: generated.bookmarkInsights,
                    model: model,
                    createdAt: createdAt
                )
            } else {
                let summary = SummaryRecord(
                    overview: generated.overview,
                    keyPoints: generated.keyPoints,
                    decisions: generated.decisions,
                    actionItems: generated.actionItems,
                    bookmarkInsights: generated.bookmarkInsights,
                    model: model,
                    createdAt: createdAt,
                    meeting: meeting
                )
                context.insert(summary)
                meeting.summary = summary
            }
            let suggestedTitle = generated.suggestedTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !suggestedTitle.isEmpty {
                meeting.suggestedTitle = suggestedTitle
                if meeting.title == MeetingRecord.defaultTitle {
                    meeting.title = suggestedTitle
                }
            }
            meeting.state = .summaryReady
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            if let existingSummary, let existingSnapshot {
                existingSnapshot.restore(existingSummary)
            } else if let inserted = meeting.summary {
                meeting.summary = nil
                context.delete(inserted)
            }
            meeting.stateRawValue = previousStateRawValue
            meeting.title = previousTitle
            meeting.suggestedTitle = previousSuggestedTitle
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func saveGeneratedDetailedMinutes(
        meetingID: UUID,
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        createdAt: Date = .now
    ) throws {
        let observedMeetingContentRevision = try meeting(
            id: meetingID
        ).contentRevision
        try saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: generated,
            model: model,
            promptVersion: promptVersion,
            observedMeetingContentRevision: observedMeetingContentRevision,
            replacingManualEdits: false,
            createdAt: createdAt
        )
    }

    func saveGeneratedDetailedMinutes(
        meetingID: UUID,
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        observedMeetingContentRevision: Int,
        replacingManualEdits: Bool = false,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let actualContentRevision = meeting.contentRevision
        guard observedMeetingContentRevision == actualContentRevision else {
            throw MeetingDocumentRepositoryError
                .staleMeetingContentRevision(
                    expected: observedMeetingContentRevision,
                    actual: actualContentRevision
                )
        }
        if meeting.detailedMinutes?.isManuallyEdited == true,
           !replacingManualEdits {
            throw MeetingDocumentRepositoryError
                .manualEditProtected(.detailedMinutes)
        }
        let encoded = try detailedMinutesEncoder(generated)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt
        let existingMinutes = meeting.detailedMinutes
        let existingSnapshot = existingMinutes.map(DetailedMinutesSnapshot.init)
        let contentSnapshot = try beginContentMutation(for: meeting)

        do {
            if let minutes = existingMinutes {
                let nextRevision = try MeetingDocumentRevision.next(
                    after: minutes.contentRevision
                )
                minutes.overview = generated.overview
                minutes.sectionsData = encoded.sections
                minutes.decisionsData = encoded.decisions
                minutes.actionItemsData = encoded.actionItems
                minutes.openQuestionsData = encoded.openQuestions
                minutes.model = model
                minutes.promptVersion = promptVersion
                minutes.createdAt = createdAt
                minutes.contentRevision = nextRevision
                minutes.isManuallyEdited = false
                minutes.archiveState = .localOnly
                minutes.archivedContentRevision = nil
                minutes.lastArchiveErrorCode = nil
            } else {
                let minutes = DetailedMinutesRecord(
                    overview: generated.overview,
                    sectionsData: encoded.sections,
                    decisionsData: encoded.decisions,
                    actionItemsData: encoded.actionItems,
                    openQuestionsData: encoded.openQuestions,
                    model: model,
                    promptVersion: promptVersion,
                    createdAt: createdAt,
                    contentRevision: 1,
                    meeting: meeting
                )
                context.insert(minutes)
                meeting.detailedMinutes = minutes
            }
            meeting.state = .summaryReady
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            if let existingMinutes, let existingSnapshot {
                existingSnapshot.restore(existingMinutes)
            } else if let inserted = meeting.detailedMinutes {
                meeting.detailedMinutes = nil
                context.delete(inserted)
            }
            meeting.stateRawValue = previousStateRawValue
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func updateDocumentArchiveState(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        archiveState: MeetingDocumentArchiveState,
        meetingState: RecordingState,
        errorCode: String? = nil
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt

        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            let snapshot = SummarySnapshot(summary)
            summary.archiveState = archiveState
            summary.lastArchiveErrorCode = errorCode
            if archiveState == .archived {
                summary.archivedContentRevision = summary.contentRevision
            } else if archiveState == .archiving {
                summary.archivedContentRevision = nil
            }
            meeting.state = meetingState
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                snapshot.restore(summary)
                meeting.stateRawValue = previousStateRawValue
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            let snapshot = DetailedMinutesSnapshot(minutes)
            minutes.archiveState = archiveState
            minutes.lastArchiveErrorCode = errorCode
            if archiveState == .archived {
                minutes.archivedContentRevision = minutes.contentRevision
            } else if archiveState == .archiving {
                minutes.archivedContentRevision = nil
            }
            meeting.state = meetingState
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                snapshot.restore(minutes)
                meeting.stateRawValue = previousStateRawValue
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        }
    }

    func documentArchiveSnapshot(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws -> MeetingDocumentArchiveSnapshot {
        let meeting = try meeting(id: meetingID)
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return MeetingDocumentArchiveSnapshot(
                meetingID: meetingID,
                kind: kind,
                archiveStateRawValue: summary.archiveStateRawValue,
                archivedContentRevision: summary.archivedContentRevision,
                lastArchiveErrorCode: summary.lastArchiveErrorCode,
                meetingState: meeting.state,
                meetingUpdatedAt: meeting.updatedAt
            )
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return MeetingDocumentArchiveSnapshot(
                meetingID: meetingID,
                kind: kind,
                archiveStateRawValue: minutes.archiveStateRawValue,
                archivedContentRevision: minutes.archivedContentRevision,
                lastArchiveErrorCode: minutes.lastArchiveErrorCode,
                meetingState: meeting.state,
                meetingUpdatedAt: meeting.updatedAt
            )
        }
    }

    func restoreDocumentArchiveSnapshot(
        _ snapshot: MeetingDocumentArchiveSnapshot
    ) throws {
        let meeting = try meeting(id: snapshot.meetingID)
        let currentSnapshot = try documentArchiveSnapshot(
            meetingID: snapshot.meetingID,
            kind: snapshot.kind
        )
        applyDocumentArchiveSnapshot(snapshot, to: meeting)
        do {
            try saveContext()
        } catch {
            applyDocumentArchiveSnapshot(currentSnapshot, to: meeting)
            throw error
        }
    }

    func completeDocumentArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws {
        let meeting = try meeting(id: meetingID)
        let currentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            summary.archiveState = .archived
            summary.archivedContentRevision = summary.contentRevision
            summary.lastArchiveErrorCode = nil
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            minutes.archiveState = .archived
            minutes.archivedContentRevision = minutes.contentRevision
            minutes.lastArchiveErrorCode = nil
        }
        meeting.state = allExistingDocumentsAreArchived(meeting)
            ? .archived
            : .summaryReady
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            applyDocumentArchiveSnapshot(currentSnapshot, to: meeting)
            throw error
        }
    }

    func beginNotionSync(
        meetingID: UUID,
        contentRevision: Int
    ) throws -> MeetingNotionSyncSnapshot {
        let meeting = try meeting(id: meetingID)
        guard meeting.contentRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.staleMeetingContentRevision(
                expected: contentRevision,
                actual: meeting.contentRevision
            )
        }
        let snapshot = notionSyncSnapshot(for: meeting)
        meeting.notionSyncState = .syncing
        meeting.notionSyncErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
            return snapshot
        } catch {
            restoreNotionSyncFields(from: snapshot, to: meeting)
            throw error
        }
    }

    func completeNotionSync(
        meetingID: UUID,
        contentRevision: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        let snapshot = notionSyncSnapshot(for: meeting)
        meeting.notionSyncedContentRevision = contentRevision
        meeting.notionSyncState = meeting.contentRevision == contentRevision
            ? .synced
            : .localOnly
        meeting.notionSyncErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            restoreNotionSyncFields(from: snapshot, to: meeting)
            throw error
        }
    }

    func failNotionSync(
        meetingID: UUID,
        contentRevision: Int,
        errorCode: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let snapshot = notionSyncSnapshot(for: meeting)
        if meeting.contentRevision == contentRevision {
            meeting.notionSyncState = .failed
            meeting.notionSyncErrorCode = errorCode
        } else {
            meeting.notionSyncState = .localOnly
            meeting.notionSyncErrorCode = nil
        }
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            restoreNotionSyncFields(from: snapshot, to: meeting)
            throw error
        }
    }

    func restoreNotionSyncSnapshot(
        _ snapshot: MeetingNotionSyncSnapshot
    ) throws {
        let meeting = try meeting(id: snapshot.meetingID)
        let current = notionSyncSnapshot(for: meeting)
        if meeting.contentRevision == snapshot.contentRevision {
            restoreNotionSyncFields(from: snapshot, to: meeting)
        } else {
            meeting.notionSyncedContentRevision = snapshot.syncedContentRevision
            meeting.notionSyncState = .localOnly
            meeting.notionSyncErrorCode = nil
            meeting.updatedAt = .now
        }
        do {
            try saveContext()
        } catch {
            restoreNotionSyncFields(from: current, to: meeting)
            throw error
        }
    }

    private func notionSyncSnapshot(
        for meeting: MeetingRecord
    ) -> MeetingNotionSyncSnapshot {
        MeetingNotionSyncSnapshot(
            meetingID: meeting.id,
            contentRevision: meeting.contentRevision,
            syncedContentRevision: meeting.notionSyncedContentRevision,
            syncStateRawValue: meeting.notionSyncStateRawValue,
            errorCode: meeting.notionSyncErrorCode,
            meetingUpdatedAt: meeting.updatedAt
        )
    }

    private func restoreNotionSyncFields(
        from snapshot: MeetingNotionSyncSnapshot,
        to meeting: MeetingRecord
    ) {
        meeting.notionSyncedContentRevision = snapshot.syncedContentRevision
        meeting.notionSyncStateRawValue = snapshot.syncStateRawValue
        meeting.notionSyncErrorCode = snapshot.errorCode
        meeting.updatedAt = snapshot.meetingUpdatedAt
    }

    private func applyDocumentArchiveSnapshot(
        _ snapshot: MeetingDocumentArchiveSnapshot,
        to meeting: MeetingRecord
    ) {
        switch snapshot.kind {
        case .summary:
            meeting.summary?.archiveStateRawValue =
                snapshot.archiveStateRawValue
            meeting.summary?.archivedContentRevision =
                snapshot.archivedContentRevision
            meeting.summary?.lastArchiveErrorCode =
                snapshot.lastArchiveErrorCode
        case .detailedMinutes:
            meeting.detailedMinutes?.archiveStateRawValue =
                snapshot.archiveStateRawValue
            meeting.detailedMinutes?.archivedContentRevision =
                snapshot.archivedContentRevision
            meeting.detailedMinutes?.lastArchiveErrorCode =
                snapshot.lastArchiveErrorCode
        }
        meeting.state = snapshot.meetingState
        meeting.updatedAt = snapshot.meetingUpdatedAt
    }

    private func allExistingDocumentsAreArchived(
        _ meeting: MeetingRecord
    ) -> Bool {
        let states = [
            meeting.summary?.archiveState,
            meeting.detailedMinutes?.archiveState,
        ].compactMap { $0 }
        return !states.isEmpty && states.allSatisfy { $0 == .archived }
    }

    func applySuggestedTitle(
        meetingID: UUID,
        suggestedTitle: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let trimmed = suggestedTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return }
        let willUpdateTitle = meeting.title == MeetingRecord.defaultTitle
            && meeting.title != trimmed
        guard meeting.suggestedTitle != trimmed || willUpdateTitle else {
            return
        }
        let previousTitle = meeting.title
        let previousSuggestedTitle = meeting.suggestedTitle
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        meeting.suggestedTitle = trimmed
        if meeting.title == MeetingRecord.defaultTitle {
            meeting.title = trimmed
        }
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.title = previousTitle
            meeting.suggestedTitle = previousSuggestedTitle
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    func setNotionPage(
        meetingID: UUID,
        pageID: String,
        pageURL: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        meeting.notionPageID = pageID
        meeting.notionPageURL = pageURL
        meeting.updatedAt = .now
        try saveContext()
    }

    func initializeNotionArchivePage(
        meetingID: UUID,
        pageID: String,
        pageURL: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousPageID = meeting.notionPageID
        let previousPageURL = meeting.notionPageURL
        let previousUpdatedAt = meeting.updatedAt
        let existingCheckpoint = meeting.archiveCheckpoint
        let checkpointSnapshot = existingCheckpoint.map(
            ArchiveCheckpointMutationSnapshot.init
        )
        let checkpoint: ArchiveCheckpointRecord
        if let existingCheckpoint {
            checkpoint = existingCheckpoint
        } else {
            checkpoint = ArchiveCheckpointRecord(
                notionPageID: pageID,
                nextSection: "metadata",
                nextBatchIndex: 0,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }
        do {
            checkpoint.notionPageID = pageID
            checkpoint.nextSection = "metadata"
            checkpoint.nextBatchIndex = 0
            try checkpoint.setMetadataBlockIDs([])
            try checkpoint.setPageBlockIDs([])
            try checkpoint.setPageSyncRun(nil)
            for kind in MeetingDocumentKind.allCases {
                try checkpoint.setBlockIDs([], for: kind)
                try checkpoint.setPendingRun(nil, for: kind)
            }
            checkpoint.updatedAt = .now
            meeting.notionPageID = pageID
            meeting.notionPageURL = pageURL
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            meeting.notionPageID = previousPageID
            meeting.notionPageURL = previousPageURL
            meeting.updatedAt = previousUpdatedAt
            if let existingCheckpoint, let checkpointSnapshot {
                checkpointSnapshot.restore(existingCheckpoint)
            } else {
                meeting.archiveCheckpoint = nil
                context.delete(checkpoint)
            }
            throw error
        }
    }

    func resetNotionArchiveCheckpoint(
        meetingID: UUID,
        notionPageID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousPageID = meeting.notionPageID
        let previousUpdatedAt = meeting.updatedAt
        let existingCheckpoint = meeting.archiveCheckpoint
        let checkpointSnapshot = existingCheckpoint.map(
            ArchiveCheckpointMutationSnapshot.init
        )
        let checkpoint: ArchiveCheckpointRecord
        if let existingCheckpoint {
            checkpoint = existingCheckpoint
        } else {
            checkpoint = ArchiveCheckpointRecord(
                notionPageID: notionPageID,
                nextSection: "managed",
                nextBatchIndex: 0,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }
        do {
            checkpoint.notionPageID = notionPageID
            checkpoint.nextSection = "managed"
            checkpoint.nextBatchIndex = 0
            try checkpoint.setMetadataBlockIDs([])
            try checkpoint.setPageBlockIDs([])
            try checkpoint.setPageSyncRun(nil)
            for kind in MeetingDocumentKind.allCases {
                try checkpoint.setBlockIDs([], for: kind)
                try checkpoint.setPendingRun(nil, for: kind)
            }
            checkpoint.updatedAt = .now
            meeting.notionPageID = notionPageID
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            meeting.notionPageID = previousPageID
            meeting.updatedAt = previousUpdatedAt
            if let existingCheckpoint, let checkpointSnapshot {
                checkpointSnapshot.restore(existingCheckpoint)
            } else {
                meeting.archiveCheckpoint = nil
                context.delete(checkpoint)
            }
            throw error
        }
    }

    func updateMeetingState(id: UUID, state: RecordingState) throws {
        let meeting = try meeting(id: id)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt
        meeting.state = state
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.stateRawValue = previousStateRawValue
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func markSpeakerProcessingStarted(meetingID: UUID) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.speakerDiarizationRequested,
              meeting.speakerProcessingState == .pending else {
            return
        }
        let previousStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerProcessingState = .processing
        meeting.speakerProcessingErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerProcessingStateRawValue =
                previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func beginSpeakerDiarizationRetry(meetingID: UUID) throws {
        let meeting = try meeting(id: meetingID)
        let previousState = meeting.speakerProcessingState
        let isInterruptedRetry = previousState == .processing
            && meeting.state
                .allowsInterruptedSpeakerDiarizationRetryRecovery
        guard previousState == .degraded
                || previousState == .completed
                || isInterruptedRetry else {
            throw MeetingRepositoryError.invalidState(previousState)
        }

        let previousRequested = meeting.speakerDiarizationRequestedBacking
        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerDiarizationRequested = true
        meeting.speakerProcessingState = .processing
        meeting.speakerProcessingErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerDiarizationRequestedBacking = previousRequested
            meeting.speakerProcessingStateRawValue = previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func completeSpeakerDiarizationRetry(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int,
        speakerDisplayNames: [String: String] = [:],
        degradationErrorCode: String? = nil
    ) throws {
        let transactionContext = ModelContext(container)
        transactionContext.autosaveEnabled = false
        let meeting = try meeting(id: meetingID, in: transactionContext)
        guard meeting.speakerProcessingState == .processing else {
            throw MeetingRepositoryError.invalidState(
                meeting.speakerProcessingState
            )
        }

        let previousTranscripts = meeting.transcripts
        let previousSpeakerNames = meeting.speakerNames
        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        let contentSnapshot = try beginContentMutation(for: meeting)
        let replacements = drafts.enumerated().map { sequenceIndex, draft in
            TranscriptRecord(
                startTime: draft.transcript.startTime,
                endTime: draft.transcript.endTime,
                text: draft.transcript.text,
                isFinal: true,
                speakerID: draft.speakerID,
                sourceRawValue: draft.source.rawValue,
                sourceRevision: sourceRevision,
                sequenceIndex: sequenceIndex
            )
        }
        let now = Date.now
        let replacementSpeakerNames = speakerDisplayNames
            .sorted { $0.key < $1.key }
            .compactMap { speakerID, displayName -> SpeakerNameRecord? in
                guard let normalizedName = AppSettingsStore
                    .normalizedSpeakerNames([displayName]).first else {
                    return nil
                }
                let matching = replacements.filter {
                    $0.speakerID == speakerID
                }
                guard let evidenceStartTime = matching.map(\.startTime).min(),
                      let evidenceEndTime = matching.map(\.endTime).max() else {
                    return nil
                }
                return SpeakerNameRecord(
                    speakerID: speakerID,
                    displayName: normalizedName,
                    evidenceStartTime: evidenceStartTime,
                    evidenceEndTime: evidenceEndTime,
                    createdAt: now,
                    updatedAt: now
                )
            }

        let correctionRebinds = Self.rebindTranscriptCorrections(
            meeting.transcriptCorrections,
            to: replacements
        )
        replacements.forEach(transactionContext.insert)
        replacementSpeakerNames.forEach(transactionContext.insert)
        meeting.transcripts = replacements
        meeting.speakerNames = replacementSpeakerNames
        meeting.speakerProcessingState = degradationErrorCode == nil
            ? .completed
            : .degraded
        meeting.speakerProcessingErrorCode = degradationErrorCode
        meeting.updatedAt = .now
        previousTranscripts.forEach(transactionContext.delete)
        previousSpeakerNames.forEach(transactionContext.delete)
        do {
            try contextSaver(transactionContext)
            synchronizeRegisteredCorrections(correctionRebinds)
        } catch {
            transactionContext.rollback()
            correctionRebinds.forEach { $0.restore() }
            meeting.transcripts = previousTranscripts
            meeting.speakerNames = previousSpeakerNames
            meeting.speakerProcessingStateRawValue = previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            contentSnapshot.restore(meeting)
            throw error
        }
    }

    private static func rebindTranscriptCorrections(
        _ corrections: [TranscriptCorrectionRecord],
        to replacements: [TranscriptRecord]
    ) -> [TranscriptCorrectionRebind] {
        let resolvedCorrections = TranscriptCorrectionResolver.resolve(
            transcripts: replacements,
            corrections: corrections
        )
        let replacementIDs = Set(replacements.map(\.id))
        var rebinds: [TranscriptCorrectionRebind] = []
        for correction in corrections {
            guard let resolved = resolvedCorrections.first(where: {
                $0.id == correction.id
            }),
                  !resolved.transcriptIDs.isEmpty,
                  resolved.transcriptIDs.allSatisfy(
                    replacementIDs.contains
                  ) else {
                continue
            }
            rebinds.append(TranscriptCorrectionRebind(correction))
            correction.transcriptIDs = resolved.transcriptIDs
            correction.anchorStartTime = resolved.startTime
            correction.anchorEndTime = resolved.endTime
            correction.source = resolved.source
        }
        return rebinds
    }

    private func synchronizeRegisteredCorrections(
        _ rebinds: [TranscriptCorrectionRebind]
    ) {
        for rebind in rebinds {
            guard let correction: TranscriptCorrectionRecord =
                context.registeredModel(
                    for: rebind.persistentModelID
                ) else {
                continue
            }
            rebind.applyCurrentState(to: correction)
        }
    }

    func failSpeakerDiarizationRetry(
        meetingID: UUID,
        errorCode: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.speakerProcessingState == .processing else {
            throw MeetingRepositoryError.invalidState(
                meeting.speakerProcessingState
            )
        }

        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode = errorCode
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerProcessingStateRawValue = previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func finalizeMeeting(
        id: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        sourceDegradationErrorCode: String? = nil
    ) throws {
        let meeting = try meeting(id: id)
        let previousStateRawValue = meeting.stateRawValue
        let previousEndedAt = meeting.endedAt
        let previousActiveDuration = meeting.activeDuration
        let previousUpdatedAt = meeting.updatedAt
        let previousSpeakerProcessingStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousSpeakerProcessingErrorCode =
            meeting.speakerProcessingErrorCode
        meeting.state = .ready
        meeting.endedAt = endedAt
        meeting.activeDuration = activeDuration
        meeting.updatedAt = endedAt
        if let sourceDegradationErrorCode {
            meeting.speakerProcessingState = .degraded
            meeting.speakerProcessingErrorCode =
                sourceDegradationErrorCode
        } else if meeting.speakerProcessingState != .degraded,
                  meeting.speakerDiarizationRequested {
            meeting.speakerProcessingState = .completed
            meeting.speakerProcessingErrorCode = nil
        }
        do {
            try saveContext()
        } catch {
            meeting.stateRawValue = previousStateRawValue
            meeting.endedAt = previousEndedAt
            meeting.activeDuration = previousActiveDuration
            meeting.updatedAt = previousUpdatedAt
            meeting.speakerProcessingStateRawValue =
                previousSpeakerProcessingStateRawValue
            meeting.speakerProcessingErrorCode =
                previousSpeakerProcessingErrorCode
            throw error
        }
    }

    func finalizeInterruptedMeeting(
        id: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        lastErrorCode: String
    ) throws {
        let meeting = try meeting(id: id)
        let previousStateRawValue = meeting.stateRawValue
        let previousEndedAt = meeting.endedAt
        let previousActiveDuration = meeting.activeDuration
        let previousLastErrorCode = meeting.lastErrorCode
        let previousUpdatedAt = meeting.updatedAt
        let previousSpeakerProcessingStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousSpeakerProcessingErrorCode =
            meeting.speakerProcessingErrorCode

        meeting.state = .ready
        meeting.endedAt = endedAt
        meeting.activeDuration = max(0, activeDuration)
        meeting.lastErrorCode = lastErrorCode
        meeting.updatedAt = endedAt
        if meeting.speakerDiarizationRequested {
            meeting.speakerProcessingState = .degraded
            meeting.speakerProcessingErrorCode =
                "speaker_diarization_capture_interrupted"
        }

        do {
            try saveContext()
        } catch {
            meeting.stateRawValue = previousStateRawValue
            meeting.endedAt = previousEndedAt
            meeting.activeDuration = previousActiveDuration
            meeting.lastErrorCode = previousLastErrorCode
            meeting.updatedAt = previousUpdatedAt
            meeting.speakerProcessingStateRawValue =
                previousSpeakerProcessingStateRawValue
            meeting.speakerProcessingErrorCode =
                previousSpeakerProcessingErrorCode
            throw error
        }
    }

    func documentContentRevision(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws -> Int {
        let meeting = try meeting(id: meetingID)
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return summary.contentRevision
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return minutes.contentRevision
        }
    }

    func beginNotionPageSyncRun(
        meetingID: UUID,
        contentRevision: Int,
        snapshotData: Data,
        oldBlockIDs: [String]
    ) throws -> NotionPageSyncRun {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              try checkpoint.pageSyncRun() == nil,
              meeting.contentRevision == contentRevision,
              Self.areCanonicalUniqueBlockIDs(oldBlockIDs),
              let content = try? JSONDecoder().decode(
                  NotionMeetingPageContent.self,
                  from: snapshotData
              ),
              content.contentRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        let run = NotionPageSyncRun(
            contentRevision: contentRevision,
            snapshotData: snapshotData,
            oldBlockIDs: oldBlockIDs
        )
        try checkpoint.setPageSyncRun(run)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
            return run
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func recordNotionPageSyncBatch(
        meetingID: UUID,
        contentRevision: Int,
        blockIDs: [String],
        nextBatchIndex: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pageSyncRun(),
              run.contentRevision == contentRevision,
              run.phase == .appendingNew,
              nextBatchIndex == run.nextBatchIndex + 1,
              !blockIDs.isEmpty,
              Self.areCanonicalUniqueBlockIDs(blockIDs),
              Set(blockIDs).isDisjoint(with: run.oldBlockIDs),
              Set(blockIDs).isDisjoint(with: run.newBlockIDs) else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        run.newBlockIDs.append(contentsOf: blockIDs)
        run.nextBatchIndex = nextBatchIndex
        try checkpoint.setPageSyncRun(run)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func transitionNotionPageSyncRun(
        meetingID: UUID,
        contentRevision: Int,
        to phase: NotionPageSyncPhase
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pageSyncRun(),
              run.contentRevision == contentRevision,
              run.phase == .appendingNew,
              phase == .rollingBackPartialNew || phase == .cleaningOld else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        run.phase = phase
        try checkpoint.setPageSyncRun(run)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func recordNotionPageSyncBlockRemoval(
        meetingID: UUID,
        contentRevision: Int,
        blockID: String,
        phase: NotionPageSyncPhase
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pageSyncRun(),
              run.contentRevision == contentRevision,
              run.phase == phase else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        switch phase {
        case .rollingBackPartialNew:
            guard run.newBlockIDs.contains(blockID) else {
                throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
            }
            run.newBlockIDs.removeAll { $0 == blockID }
        case .cleaningOld:
            guard run.oldBlockIDs.contains(blockID) else {
                throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
            }
            run.oldBlockIDs.removeAll { $0 == blockID }
        case .appendingNew:
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }

        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        try checkpoint.setPageSyncRun(run)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func finishNotionPageSyncRollback(
        meetingID: UUID,
        contentRevision: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              let run = try checkpoint.pageSyncRun(),
              run.contentRevision == contentRevision,
              run.phase == .rollingBackPartialNew,
              run.newBlockIDs.isEmpty else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        try checkpoint.setPageSyncRun(nil)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func completeNotionPageSyncRun(
        meetingID: UUID,
        contentRevision: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              let run = try checkpoint.pageSyncRun(),
              run.contentRevision == contentRevision,
              run.phase == .cleaningOld,
              run.oldBlockIDs.isEmpty else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let syncSnapshot = notionSyncSnapshot(for: meeting)
        try checkpoint.setPageBlockIDs(run.newBlockIDs)
        try checkpoint.setPageSyncRun(nil)
        meeting.notionSyncedContentRevision = contentRevision
        meeting.notionSyncState = meeting.contentRevision == contentRevision
            ? .synced
            : .localOnly
        meeting.notionSyncErrorCode = nil
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            restoreNotionSyncFields(from: syncSnapshot, to: meeting)
            throw error
        }
    }

    func beginDocumentArchiveRun(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int
    ) throws -> NotionDocumentArchiveRun {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint else {
            throw MeetingDocumentRepositoryError.missingArchiveCheckpoint
        }
        let actualRevision = try documentContentRevision(
            meetingID: meetingID,
            kind: kind
        )
        guard actualRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.staleDocumentRevision(
                kind,
                expected: contentRevision,
                actual: actualRevision
            )
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )

        let run: NotionDocumentArchiveRun
        if let existing = try checkpoint.pendingRun(for: kind),
           existing.contentRevision == contentRevision {
            run = existing
        } else {
            let existing = try checkpoint.pendingRun(for: kind)
            let staleIDs = Self.uniqueBlockIDs(
                try checkpoint.blockIDs(for: kind)
                    + (existing?.newBlockIDs ?? [])
                    + (existing?.oldBlockIDs ?? [])
            )
            run = NotionDocumentArchiveRun(
                contentRevision: contentRevision,
                oldBlockIDs: staleIDs
            )
            try checkpoint.setPendingRun(run, for: kind)
        }
        setDocumentArchiveStatus(
            meeting: meeting,
            kind: kind,
            state: .archiving,
            archivedRevision: documentSnapshot.archivedContentRevision,
            errorCode: nil
        )
        meeting.state = .summaryReady
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
            return run
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    func recordDocumentArchiveBatch(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int,
        blockIDs: [String],
        nextBatchIndex: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .appending,
              nextBatchIndex == run.nextBatchIndex + 1 else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let snapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        run.newBlockIDs.append(contentsOf: blockIDs)
        run.nextBatchIndex = nextBatchIndex
        try checkpoint.setPendingRun(run, for: kind)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            snapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func recordMetadataArchiveBatch(
        meetingID: UUID,
        notionPageID: String,
        blockIDs: [String],
        nextBatchIndex: Int,
        batchCount: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              checkpoint.notionPageID == notionPageID,
              checkpoint.nextSection == "metadata",
              nextBatchIndex == checkpoint.nextBatchIndex + 1,
              nextBatchIndex <= batchCount else {
            throw MeetingDocumentRepositoryError
                .invalidMetadataArchiveCheckpoint
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        let previousIDs = try checkpoint.metadataBlockIDs
        try checkpoint.setMetadataBlockIDs(previousIDs + blockIDs)
        checkpoint.nextSection = nextBatchIndex == batchCount
            ? "managed"
            : "metadata"
        checkpoint.nextBatchIndex = nextBatchIndex == batchCount
            ? 0
            : nextBatchIndex
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func promoteDocumentArchiveRun(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .appending else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let actualRevision = try documentContentRevision(
            meetingID: meetingID,
            kind: kind
        )
        guard actualRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.staleDocumentRevision(
                kind,
                expected: contentRevision,
                actual: actualRevision
            )
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )

        try checkpoint.setBlockIDs(run.newBlockIDs, for: kind)
        if run.oldBlockIDs.isEmpty {
            try checkpoint.setPendingRun(nil, for: kind)
        } else {
            run.phase = .cleaningUp
            try checkpoint.setPendingRun(run, for: kind)
        }
        setDocumentArchiveStatus(
            meeting: meeting,
            kind: kind,
            state: .archived,
            archivedRevision: contentRevision,
            errorCode: nil
        )
        meeting.state = allExistingDocumentsAreArchived(meeting)
            ? .archived
            : .summaryReady
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    func recordArchivedDocumentBlock(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int,
        blockID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .cleaningUp,
              run.oldBlockIDs.contains(blockID) else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )
        run.oldBlockIDs.removeAll { $0 == blockID }
        if run.oldBlockIDs.isEmpty {
            try checkpoint.setPendingRun(nil, for: kind)
            let actualRevision = try documentContentRevision(
                meetingID: meetingID,
                kind: kind
            )
            if actualRevision == contentRevision {
                setDocumentArchiveStatus(
                    meeting: meeting,
                    kind: kind,
                    state: .archived,
                    archivedRevision: contentRevision,
                    errorCode: nil
                )
                meeting.state = allExistingDocumentsAreArchived(meeting)
                    ? .archived
                    : .summaryReady
            }
        } else {
            try checkpoint.setPendingRun(run, for: kind)
        }
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    private func setDocumentArchiveStatus(
        meeting: MeetingRecord,
        kind: MeetingDocumentKind,
        state: MeetingDocumentArchiveState,
        archivedRevision: Int?,
        errorCode: String?
    ) {
        switch kind {
        case .summary:
            meeting.summary?.archiveState = state
            meeting.summary?.archivedContentRevision = archivedRevision
            meeting.summary?.lastArchiveErrorCode = errorCode
        case .detailedMinutes:
            meeting.detailedMinutes?.archiveState = state
            meeting.detailedMinutes?.archivedContentRevision = archivedRevision
            meeting.detailedMinutes?.lastArchiveErrorCode = errorCode
        }
    }

    private static func uniqueBlockIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func areCanonicalUniqueBlockIDs(_ ids: [String]) -> Bool {
        guard ids.allSatisfy({
            !$0.isEmpty
                && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }) else {
            return false
        }
        return Set(ids).count == ids.count
    }

    func saveArchiveCheckpoint(
        meetingID: UUID,
        notionPageID: String,
        nextSection: String,
        nextBatchIndex: Int,
        updatedAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)

        if let checkpoint = meeting.archiveCheckpoint {
            checkpoint.notionPageID = notionPageID
            checkpoint.nextSection = nextSection
            checkpoint.nextBatchIndex = nextBatchIndex
            checkpoint.updatedAt = updatedAt
        } else {
            let checkpoint = ArchiveCheckpointRecord(
                notionPageID: notionPageID,
                nextSection: nextSection,
                nextBatchIndex: nextBatchIndex,
                updatedAt: updatedAt,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }

        meeting.updatedAt = .now
        try saveContext()
    }

    func deleteMeeting(id: UUID) throws {
        let meeting = try meeting(id: id)
        context.delete(meeting)
        try saveContext()
    }

    func count<Model: PersistentModel>(_ model: Model.Type) throws -> Int {
        _ = model
        return try context.fetchCount(FetchDescriptor<Model>())
    }

    private func saveContext() throws {
        try contextSaver(context)
    }

    private func beginContentMutation(
        for meeting: MeetingRecord
    ) throws -> MeetingContentMutationSnapshot {
        let snapshot = MeetingContentMutationSnapshot(meeting)
        meeting.contentRevision = try MeetingContentRevision.next(
            after: meeting.contentRevision
        )
        meeting.notionSyncState = .localOnly
        meeting.notionSyncErrorCode = nil
        return snapshot
    }

    private static func meetingComesBefore(
        _ lhs: MeetingRecord,
        _ rhs: MeetingRecord
    ) -> Bool {
        switch (lhs.pinnedAt, rhs.pinnedAt) {
        case let (lhsPinnedAt?, rhsPinnedAt?) where lhsPinnedAt != rhsPinnedAt:
            return lhsPinnedAt > rhsPinnedAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func transcriptComesBefore(
        _ lhs: TranscriptRecord,
        _ rhs: TranscriptRecord
    ) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        switch (lhs.sequenceIndex, rhs.sequenceIndex) {
        case let (lhsSequence?, rhsSequence?)
            where lhsSequence != rhsSequence:
            return lhsSequence < rhsSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func noteComesBefore(
        _ lhs: MeetingNoteRecord,
        _ rhs: MeetingNoteRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func screenshotComesBefore(
        _ lhs: MeetingScreenshotRecord,
        _ rhs: MeetingScreenshotRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func isValidScreenshotRelativePath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized == path,
              !NSString(string: normalized).isAbsolutePath else {
            return false
        }
        return !NSString(string: normalized).pathComponents.contains {
            $0 == "." || $0 == ".."
        }
    }

    private static func sanitizedTimelineTimestamp(
        _ timestamp: TimeInterval
    ) -> TimeInterval {
        guard timestamp.isFinite else { return 0 }
        return max(0, timestamp)
    }
}

private struct TranscriptCorrectionRebind {
    private let correction: TranscriptCorrectionRecord
    private let transcriptIDsData: Data
    private let anchorStartTime: TimeInterval
    private let anchorEndTime: TimeInterval
    private let sourceRawValue: String

    init(_ correction: TranscriptCorrectionRecord) {
        self.correction = correction
        transcriptIDsData = correction.transcriptIDsData
        anchorStartTime = correction.anchorStartTime
        anchorEndTime = correction.anchorEndTime
        sourceRawValue = correction.sourceRawValue
    }

    var persistentModelID: PersistentIdentifier {
        correction.persistentModelID
    }

    func applyCurrentState(to target: TranscriptCorrectionRecord) {
        target.transcriptIDsData = correction.transcriptIDsData
        target.anchorStartTime = correction.anchorStartTime
        target.anchorEndTime = correction.anchorEndTime
        target.sourceRawValue = correction.sourceRawValue
    }

    func restore() {
        correction.transcriptIDsData = transcriptIDsData
        correction.anchorStartTime = anchorStartTime
        correction.anchorEndTime = anchorEndTime
        correction.sourceRawValue = sourceRawValue
    }
}

private struct ExactMeetingReplacementPlan {
    let preview: MeetingExactReplacementPreview
    let transcripts: [ExactTranscriptReplacement]
    let speakers: [ExactSpeakerReplacement]
    let summary: ExactSummaryReplacement?
    let detailedMinutes: ExactDetailedMinutesReplacement?
}

private struct ExactTranscriptReplacement {
    let entry: CanonicalTranscriptEntry
    let correction: TranscriptCorrectionRecord?
    let replacementText: String
}

private struct ExactSpeakerReplacement {
    let record: SpeakerNameRecord
    let displayName: String
}

private struct ExactSummaryReplacement {
    let record: SummaryRecord
    let overview: String?
    let keyPointsData: Data?
    let decisionsData: Data?
    let actionItemsData: Data?
    let bookmarkInsightsData: Data?
    let matches: Int
}

private struct ExactDetailedMinutesReplacement {
    let record: DetailedMinutesRecord
    let overview: String?
    let sectionsData: Data?
    let decisionsData: Data?
    let actionItemsData: Data?
    let openQuestionsData: Data?
    let matches: Int
}

private struct ExactStructuredDataReplacement {
    let data: Data?
    let matches: Int
}

private struct ExactTranscriptCorrectionSnapshot {
    let replacementText: String
    let updatedAt: Date

    init(_ correction: TranscriptCorrectionRecord) {
        replacementText = correction.replacementText
        updatedAt = correction.updatedAt
    }

    func restore(_ correction: TranscriptCorrectionRecord) {
        correction.replacementText = replacementText
        correction.updatedAt = updatedAt
    }
}

private struct ArchiveCheckpointMutationSnapshot {
    let notionPageID: String
    let nextSection: String
    let nextBatchIndex: Int
    let metadataBlockIDsData: Data?
    let summaryBlockIDsData: Data?
    let detailedMinutesBlockIDsData: Data?
    let pageBlockIDsData: Data?
    let pageSyncRunData: Data?
    let pendingKindRawValue: String?
    let pendingNewBlockIDsData: Data?
    let pendingOldBlockIDsData: Data?
    let pendingNextBatchIndex: Int?
    let pendingContentRevision: Int?
    let pendingPhaseRawValue: String?
    let pendingRunsData: Data?
    let updatedAt: Date

    init(_ checkpoint: ArchiveCheckpointRecord) {
        notionPageID = checkpoint.notionPageID
        nextSection = checkpoint.nextSection
        nextBatchIndex = checkpoint.nextBatchIndex
        metadataBlockIDsData = checkpoint.metadataBlockIDsData
        summaryBlockIDsData = checkpoint.summaryBlockIDsData
        detailedMinutesBlockIDsData = checkpoint.detailedMinutesBlockIDsData
        pageBlockIDsData = checkpoint.pageBlockIDsData
        pageSyncRunData = checkpoint.pageSyncRunData
        pendingKindRawValue = checkpoint.pendingKindRawValue
        pendingNewBlockIDsData = checkpoint.pendingNewBlockIDsData
        pendingOldBlockIDsData = checkpoint.pendingOldBlockIDsData
        pendingNextBatchIndex = checkpoint.pendingNextBatchIndex
        pendingContentRevision = checkpoint.pendingContentRevision
        pendingPhaseRawValue = checkpoint.pendingPhaseRawValue
        pendingRunsData = checkpoint.pendingRunsData
        updatedAt = checkpoint.updatedAt
    }

    func restore(_ checkpoint: ArchiveCheckpointRecord) {
        checkpoint.notionPageID = notionPageID
        checkpoint.nextSection = nextSection
        checkpoint.nextBatchIndex = nextBatchIndex
        checkpoint.metadataBlockIDsData = metadataBlockIDsData
        checkpoint.summaryBlockIDsData = summaryBlockIDsData
        checkpoint.detailedMinutesBlockIDsData = detailedMinutesBlockIDsData
        checkpoint.pageBlockIDsData = pageBlockIDsData
        checkpoint.pageSyncRunData = pageSyncRunData
        checkpoint.pendingKindRawValue = pendingKindRawValue
        checkpoint.pendingNewBlockIDsData = pendingNewBlockIDsData
        checkpoint.pendingOldBlockIDsData = pendingOldBlockIDsData
        checkpoint.pendingNextBatchIndex = pendingNextBatchIndex
        checkpoint.pendingContentRevision = pendingContentRevision
        checkpoint.pendingPhaseRawValue = pendingPhaseRawValue
        checkpoint.pendingRunsData = pendingRunsData
        checkpoint.updatedAt = updatedAt
    }
}

private struct SummarySnapshot {
    let overview: String
    let keyPointsData: Data
    let decisionsData: Data
    let actionItemsData: Data
    let bookmarkInsightsData: Data
    let model: String
    let createdAt: Date
    let contentRevisionBacking: Int?
    let archiveStateRawValue: String?
    let archivedContentRevision: Int?
    let lastArchiveErrorCode: String?
    let isManuallyEditedBacking: Bool?

    init(_ summary: SummaryRecord) {
        overview = summary.overview
        keyPointsData = summary.keyPointsData
        decisionsData = summary.decisionsData
        actionItemsData = summary.actionItemsData
        bookmarkInsightsData = summary.bookmarkInsightsData
        model = summary.model
        createdAt = summary.createdAt
        contentRevisionBacking = summary.contentRevisionBacking
        archiveStateRawValue = summary.archiveStateRawValue
        archivedContentRevision = summary.archivedContentRevision
        lastArchiveErrorCode = summary.lastArchiveErrorCode
        isManuallyEditedBacking = summary.isManuallyEditedBacking
    }

    func restore(_ summary: SummaryRecord) {
        summary.overview = overview
        summary.keyPointsData = keyPointsData
        summary.decisionsData = decisionsData
        summary.actionItemsData = actionItemsData
        summary.bookmarkInsightsData = bookmarkInsightsData
        summary.model = model
        summary.createdAt = createdAt
        summary.contentRevisionBacking = contentRevisionBacking
        summary.archiveStateRawValue = archiveStateRawValue
        summary.archivedContentRevision = archivedContentRevision
        summary.lastArchiveErrorCode = lastArchiveErrorCode
        summary.isManuallyEditedBacking = isManuallyEditedBacking
    }
}

private struct DetailedMinutesSnapshot {
    let overview: String
    let sectionsData: Data
    let decisionsData: Data
    let actionItemsData: Data
    let openQuestionsData: Data
    let model: String
    let promptVersion: Int
    let createdAt: Date
    let contentRevisionBacking: Int?
    let archiveStateRawValue: String?
    let archivedContentRevision: Int?
    let lastArchiveErrorCode: String?
    let isManuallyEditedBacking: Bool?

    init(_ minutes: DetailedMinutesRecord) {
        overview = minutes.overview
        sectionsData = minutes.sectionsData
        decisionsData = minutes.decisionsData
        actionItemsData = minutes.actionItemsData
        openQuestionsData = minutes.openQuestionsData
        model = minutes.model
        promptVersion = minutes.promptVersion
        createdAt = minutes.createdAt
        contentRevisionBacking = minutes.contentRevisionBacking
        archiveStateRawValue = minutes.archiveStateRawValue
        archivedContentRevision = minutes.archivedContentRevision
        lastArchiveErrorCode = minutes.lastArchiveErrorCode
        isManuallyEditedBacking = minutes.isManuallyEditedBacking
    }

    func restore(_ minutes: DetailedMinutesRecord) {
        minutes.overview = overview
        minutes.sectionsData = sectionsData
        minutes.decisionsData = decisionsData
        minutes.actionItemsData = actionItemsData
        minutes.openQuestionsData = openQuestionsData
        minutes.model = model
        minutes.promptVersion = promptVersion
        minutes.createdAt = createdAt
        minutes.contentRevisionBacking = contentRevisionBacking
        minutes.archiveStateRawValue = archiveStateRawValue
        minutes.archivedContentRevision = archivedContentRevision
        minutes.lastArchiveErrorCode = lastArchiveErrorCode
        minutes.isManuallyEditedBacking = isManuallyEditedBacking
    }
}

private struct MeetingContentMutationSnapshot {
    let contentRevisionBacking: Int?
    let notionSyncStateRawValue: String?
    let notionSyncErrorCode: String?

    init(_ meeting: MeetingRecord) {
        contentRevisionBacking = meeting.contentRevisionBacking
        notionSyncStateRawValue = meeting.notionSyncStateRawValue
        notionSyncErrorCode = meeting.notionSyncErrorCode
    }

    func restore(_ meeting: MeetingRecord) {
        meeting.contentRevisionBacking = contentRevisionBacking
        meeting.notionSyncStateRawValue = notionSyncStateRawValue
        meeting.notionSyncErrorCode = notionSyncErrorCode
    }
}

private struct MeetingNoteSnapshot {
    let timestamp: TimeInterval
    let text: String
    let createdAt: Date
    let updatedAt: Date
    let sequenceIndex: Int

    init(_ note: MeetingNoteRecord) {
        timestamp = note.timestamp
        text = note.text
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        sequenceIndex = note.sequenceIndex
    }

    func restore(_ note: MeetingNoteRecord) {
        note.timestamp = timestamp
        note.text = text
        note.createdAt = createdAt
        note.updatedAt = updatedAt
        note.sequenceIndex = sequenceIndex
    }
}

private struct MeetingScreenshotSnapshot {
    let timestamp: TimeInterval
    let relativePath: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let createdAt: Date
    let sequenceIndex: Int

    init(_ screenshot: MeetingScreenshotRecord) {
        timestamp = screenshot.timestamp
        relativePath = screenshot.relativePath
        pixelWidth = screenshot.pixelWidth
        pixelHeight = screenshot.pixelHeight
        byteCount = screenshot.byteCount
        createdAt = screenshot.createdAt
        sequenceIndex = screenshot.sequenceIndex
    }

    func restore(_ screenshot: MeetingScreenshotRecord) {
        screenshot.timestamp = timestamp
        screenshot.relativePath = relativePath
        screenshot.pixelWidth = pixelWidth
        screenshot.pixelHeight = pixelHeight
        screenshot.byteCount = byteCount
        screenshot.createdAt = createdAt
        screenshot.sequenceIndex = sequenceIndex
    }
}

private struct SpeakerNameSnapshot {
    let speakerID: String
    let displayName: String
    let evidenceStartTime: TimeInterval
    let evidenceEndTime: TimeInterval
    let createdAt: Date
    let updatedAt: Date

    init(_ record: SpeakerNameRecord) {
        speakerID = record.speakerID
        displayName = record.displayName
        evidenceStartTime = record.evidenceStartTime
        evidenceEndTime = record.evidenceEndTime
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    func restore(_ record: SpeakerNameRecord) {
        record.speakerID = speakerID
        record.displayName = displayName
        record.evidenceStartTime = evidenceStartTime
        record.evidenceEndTime = evidenceEndTime
        record.createdAt = createdAt
        record.updatedAt = updatedAt
    }
}
