import Foundation

enum NotionArchiveServiceError: Error, Equatable, Sendable {
    case archiveInProgress(UUID)
}

@MainActor
final class NotionArchiveService {
    private enum CheckpointSection {
        static let metadata = "metadata"
        static let managed = "managed"
    }

    private let repository: MeetingRepository
    private let client: any NotionAPIClient
    private let blockBuilder: NotionBlockBuilder
    private static var activeMeetingIDs: Set<UUID> = []

    init(
        repository: MeetingRepository,
        client: any NotionAPIClient,
        blockBuilder: NotionBlockBuilder = NotionBlockBuilder()
    ) {
        self.repository = repository
        self.client = client
        self.blockBuilder = blockBuilder
    }

    func archive(
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference {
        guard Self.activeMeetingIDs.insert(meetingID).inserted else {
            throw NotionArchiveServiceError.archiveInProgress(meetingID)
        }
        defer { Self.activeMeetingIDs.remove(meetingID) }
        do {
            let page = try await page(
                meetingID: meetingID,
                parentPageID: parentPageID,
                content: content
            )
            try await appendMetadataIfNeeded(
                meetingID: meetingID,
                pageID: page.id,
                content: content
            )
            try await replaceManagedSection(
                meetingID: meetingID,
                pageID: page.id,
                content: content
            )
            return page
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            try? repository.updateDocumentArchiveState(
                meetingID: meetingID,
                kind: content.kind,
                archiveState: .failed,
                meetingState: .summaryReady,
                errorCode: "notion_archive_failed"
            )
            throw error
        }
    }

    private func page(
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference {
        let meeting = try repository.meeting(id: meetingID)
        if let existingPageID = meeting.notionPageID {
            if meeting.archiveCheckpoint?.notionPageID != existingPageID {
                try repository.resetNotionArchiveCheckpoint(
                    meetingID: meetingID,
                    notionPageID: existingPageID
                )
            } else if let checkpoint = meeting.archiveCheckpoint,
                      checkpoint.nextSection != CheckpointSection.metadata,
                      checkpoint.nextSection != CheckpointSection.managed {
                // A checkpoint written by the previous whole-page archiver does
                // not identify its blocks. Preserve that page as legacy content
                // and start the first managed section without deleting anything.
                try repository.saveArchiveCheckpoint(
                    meetingID: meetingID,
                    notionPageID: existingPageID,
                    nextSection: CheckpointSection.managed,
                    nextBatchIndex: 0
                )
            }
            return NotionPageReference(
                id: existingPageID,
                url: meeting.notionPageURL ?? Self.fallbackURL(for: existingPageID)
            )
        }

        let created = try await client.createPage(
            parentPageID: parentPageID,
            title: content.title
        )
        try repository.initializeNotionArchivePage(
            meetingID: meetingID,
            pageID: created.id,
            pageURL: created.url
        )
        return created
    }

    private func appendMetadataIfNeeded(
        meetingID: UUID,
        pageID: String,
        content: NotionMeetingPageContent
    ) async throws {
        let meeting = try repository.meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              checkpoint.notionPageID == pageID,
              checkpoint.nextSection == CheckpointSection.metadata else {
            return
        }
        let batches = blockBuilder.batches(
            of: blockBuilder.metadataBlocks(for: content)
        )
        let startIndex = min(max(0, checkpoint.nextBatchIndex), batches.count)
        for index in startIndex..<batches.count {
            let blockIDs = try await client.append(
                blocks: batches[index],
                to: pageID
            )
            try await persistAppendedBatch(blockIDs: blockIDs) {
                try repository.recordMetadataArchiveBatch(
                    meetingID: meetingID,
                    notionPageID: pageID,
                    blockIDs: blockIDs,
                    nextBatchIndex: index + 1,
                    batchCount: batches.count
                )
            }
        }
        if startIndex == batches.count {
            try repository.saveArchiveCheckpoint(
                meetingID: meetingID,
                notionPageID: pageID,
                nextSection: CheckpointSection.managed,
                nextBatchIndex: 0
            )
        }
    }

    private func replaceManagedSection(
        meetingID: UUID,
        pageID: String,
        content: NotionMeetingPageContent
    ) async throws {
        let contentRevision = try repository.documentContentRevision(
            meetingID: meetingID,
            kind: content.kind
        )
        var meeting = try repository.meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint else {
            throw MeetingDocumentRepositoryError.missingArchiveCheckpoint
        }
        let meetingSnapshotAlreadySynced = content.contentRevision == 0
            || meeting.notionSyncedContentRevision == content.contentRevision
        if try checkpoint.pendingRun(for: content.kind) == nil,
           try !checkpoint.blockIDs(for: content.kind).isEmpty,
           archivedRevision(in: meeting, kind: content.kind) == contentRevision,
           meetingSnapshotAlreadySynced {
            return
        }

        var run = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: content.kind,
            contentRevision: contentRevision
        )
        if run.phase == .appending {
            let batches = blockBuilder.batches(
                of: blockBuilder.documentBlocks(for: content)
            )
            guard run.nextBatchIndex <= batches.count else {
                throw MeetingDocumentRepositoryError.invalidArchiveRun(content.kind)
            }
            for index in run.nextBatchIndex..<batches.count {
                let blockIDs = try await client.append(
                    blocks: batches[index],
                    to: pageID
                )
                try await persistAppendedBatch(blockIDs: blockIDs) {
                    try repository.recordDocumentArchiveBatch(
                        meetingID: meetingID,
                        kind: content.kind,
                        contentRevision: contentRevision,
                        blockIDs: blockIDs,
                        nextBatchIndex: index + 1
                    )
                }
            }
            try repository.promoteDocumentArchiveRun(
                meetingID: meetingID,
                kind: content.kind,
                contentRevision: contentRevision
            )
        }

        meeting = try repository.meeting(id: meetingID)
        run = try meeting.archiveCheckpoint?.pendingRun(for: content.kind)
            ?? NotionDocumentArchiveRun(contentRevision: contentRevision)
        guard run.phase == .cleaningUp else { return }
        for oldBlockID in run.oldBlockIDs {
            try await client.archiveBlock(id: oldBlockID)
            try repository.recordArchivedDocumentBlock(
                meetingID: meetingID,
                kind: content.kind,
                contentRevision: contentRevision,
                blockID: oldBlockID
            )
        }
    }

    private func persistAppendedBatch(
        blockIDs: [String],
        persist: () throws -> Void
    ) async throws {
        do {
            try persist()
            return
        } catch {
            do {
                try persist()
                return
            } catch {
                for blockID in blockIDs {
                    try? await client.archiveBlock(id: blockID)
                }
                throw error
            }
        }
    }

    private func archivedRevision(
        in meeting: MeetingRecord,
        kind: MeetingDocumentKind
    ) -> Int? {
        switch kind {
        case .summary:
            meeting.summary?.archivedContentRevision
        case .detailedMinutes:
            meeting.detailedMinutes?.archivedContentRevision
        }
    }

    private static func fallbackURL(for pageID: String) -> String {
        "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }
}
