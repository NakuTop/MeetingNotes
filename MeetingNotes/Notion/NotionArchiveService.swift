import Foundation

enum NotionArchiveServiceError: Error, Equatable, Sendable {
    case archiveInProgress(UUID)
    case screenshotSnapshotMismatch
    case screenshotUnavailable(UUID)
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
    private let fileStore: MeetingFileStore?
    private let screenshotDerivativeBuilder:
        NotionScreenshotDerivativeBuilder
    private static var activeMeetingIDs: Set<UUID> = []

    init(
        repository: MeetingRepository,
        client: any NotionAPIClient,
        blockBuilder: NotionBlockBuilder = NotionBlockBuilder(),
        fileStore: MeetingFileStore? = nil,
        screenshotDerivativeBuilder:
            NotionScreenshotDerivativeBuilder =
                NotionScreenshotDerivativeBuilder()
    ) {
        self.repository = repository
        self.client = client
        self.blockBuilder = blockBuilder
        self.fileStore = fileStore
        self.screenshotDerivativeBuilder = screenshotDerivativeBuilder
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
            let preparedContent = try await preparedContent(
                meetingID: meetingID,
                content: content
            )
            let page = try await page(
                meetingID: meetingID,
                parentPageID: parentPageID,
                content: preparedContent
            )
            if preparedContent.contentRevision > 0 {
                try await replaceWholePage(
                    meetingID: meetingID,
                    pageID: page.id,
                    content: preparedContent
                )
            } else {
                try await appendMetadataIfNeeded(
                    meetingID: meetingID,
                    pageID: page.id,
                    content: preparedContent
                )
                try await replaceManagedSection(
                    meetingID: meetingID,
                    pageID: page.id,
                    content: preparedContent
                )
            }
            return page
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            if content.contentRevision == 0 {
                try? repository.updateDocumentArchiveState(
                    meetingID: meetingID,
                    kind: content.kind,
                    archiveState: .failed,
                    meetingState: .summaryReady,
                    errorCode: "notion_archive_failed"
                )
            }
            throw error
        }
    }

    private func preparedContent(
        meetingID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionMeetingPageContent {
        if content.contentRevision > 0,
           let checkpoint = try repository.meeting(id: meetingID)
            .archiveCheckpoint,
           let run = try checkpoint.pageSyncRun(),
           run.contentRevision == content.contentRevision {
            let snapshot = try decodePageSnapshot(run.snapshotData)
            guard snapshot.contentRevision == run.contentRevision,
                  snapshot.screenshots.allSatisfy({ screenshot in
                      guard let fileUploadID = screenshot.fileUploadID else {
                          return false
                      }
                      return !fileUploadID.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                  }) else {
                throw ArchiveCheckpointCodingError.invalidData(
                    "pageSyncSnapshotData"
                )
            }
            return snapshot
        }

        let records = try repository.screenshots(meetingID: meetingID)
        let requestedIDs = content.screenshots.map(\.id)
        guard Set(requestedIDs).count == requestedIDs.count,
              Set(requestedIDs) == Set(records.map(\.id)) else {
            throw NotionArchiveServiceError.screenshotSnapshotMismatch
        }
        guard !records.isEmpty else { return content }
        guard let fileStore else {
            throw NotionArchiveServiceError.screenshotSnapshotMismatch
        }

        var preparedScreenshots: [NotionTimelineScreenshot] = []
        preparedScreenshots.reserveCapacity(records.count)
        for record in records {
            try Task.checkCancellation()
            let sourceURL: URL
            do {
                sourceURL = try await fileStore.resolveScreenshotURL(
                    meetingID: meetingID,
                    relativePath: record.relativePath
                )
            } catch {
                throw NotionArchiveServiceError.screenshotUnavailable(
                    record.id
                )
            }

            let derivative = try await screenshotDerivativeBuilder.build(
                from: sourceURL
            )
            defer { derivative.cleanup() }

            let jpeg: Data
            do {
                jpeg = try Data(contentsOf: derivative.fileURL)
            } catch {
                throw NotionArchiveServiceError.screenshotUnavailable(
                    record.id
                )
            }
            try Task.checkCancellation()
            let uploaded = try await client.uploadJPEG(
                data: jpeg,
                fileName: "meeting-screenshot-\(record.id.uuidString).jpg"
            )
            let uploadID = uploaded.id.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !uploadID.isEmpty else {
                throw NotionClientError.invalidResponse
            }
            preparedScreenshots.append(
                NotionTimelineScreenshot(
                    id: record.id,
                    timestamp: record.timestamp,
                    sequenceIndex: record.sequenceIndex,
                    fileUploadID: uploadID
                )
            )
        }
        try Task.checkCancellation()
        return try content.replacingScreenshots(with: preparedScreenshots)
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

    private func replaceWholePage(
        meetingID: UUID,
        pageID: String,
        content: NotionMeetingPageContent
    ) async throws {
        while true {
            let meeting = try repository.meeting(id: meetingID)
            guard let checkpoint = meeting.archiveCheckpoint,
                  checkpoint.notionPageID == pageID else {
                throw MeetingDocumentRepositoryError.missingArchiveCheckpoint
            }

            guard let run = try checkpoint.pageSyncRun() else {
                let oldBlockIDs = try await allChildBlockIDs(pageID: pageID)
                let snapshotData = try encodePageSnapshot(content)
                _ = try repository.beginNotionPageSyncRun(
                    meetingID: meetingID,
                    contentRevision: content.contentRevision,
                    snapshotData: snapshotData,
                    oldBlockIDs: oldBlockIDs
                )
                continue
            }

            switch run.phase {
            case .appendingNew:
                if run.contentRevision != content.contentRevision {
                    try repository.transitionNotionPageSyncRun(
                        meetingID: meetingID,
                        contentRevision: run.contentRevision,
                        to: .rollingBackPartialNew
                    )
                    try await rollBackPartialNewBlocks(
                        meetingID: meetingID,
                        contentRevision: run.contentRevision
                    )
                    continue
                }
                let snapshot = try decodePageSnapshot(run.snapshotData)
                guard snapshot.contentRevision == run.contentRevision else {
                    throw ArchiveCheckpointCodingError.invalidData(
                        "pageSyncSnapshotData"
                    )
                }
                try await appendWholePageSnapshot(
                    meetingID: meetingID,
                    pageID: pageID,
                    run: run,
                    content: snapshot
                )
                return

            case .rollingBackPartialNew:
                try await rollBackPartialNewBlocks(
                    meetingID: meetingID,
                    contentRevision: run.contentRevision
                )
                continue

            case .cleaningOld:
                try await cleanOldPageBlocks(
                    meetingID: meetingID,
                    contentRevision: run.contentRevision
                )
                if run.contentRevision == content.contentRevision {
                    return
                }
                continue
            }
        }
    }

    private func appendWholePageSnapshot(
        meetingID: UUID,
        pageID: String,
        run: NotionPageSyncRun,
        content: NotionMeetingPageContent
    ) async throws {
        let batches = blockBuilder.batches(for: content)
        guard run.nextBatchIndex <= batches.count else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        do {
            for index in run.nextBatchIndex..<batches.count {
                let blockIDs = try await client.append(
                    blocks: batches[index],
                    to: pageID
                )
                try await persistAppendedBatch(blockIDs: blockIDs) {
                    try repository.recordNotionPageSyncBatch(
                        meetingID: meetingID,
                        contentRevision: run.contentRevision,
                        blockIDs: blockIDs,
                        nextBatchIndex: index + 1
                    )
                }
            }
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            try repository.transitionNotionPageSyncRun(
                meetingID: meetingID,
                contentRevision: run.contentRevision,
                to: .rollingBackPartialNew
            )
            try await rollBackPartialNewBlocks(
                meetingID: meetingID,
                contentRevision: run.contentRevision
            )
            throw error
        }

        try repository.transitionNotionPageSyncRun(
            meetingID: meetingID,
            contentRevision: run.contentRevision,
            to: .cleaningOld
        )
        try await cleanOldPageBlocks(
            meetingID: meetingID,
            contentRevision: run.contentRevision
        )
    }

    private func rollBackPartialNewBlocks(
        meetingID: UUID,
        contentRevision: Int
    ) async throws {
        let run = try repository.meeting(id: meetingID)
            .archiveCheckpoint?.pageSyncRun()
        guard let run,
              run.contentRevision == contentRevision,
              run.phase == .rollingBackPartialNew else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        for blockID in run.newBlockIDs {
            try await client.archiveBlock(id: blockID)
            try repository.recordNotionPageSyncBlockRemoval(
                meetingID: meetingID,
                contentRevision: contentRevision,
                blockID: blockID,
                phase: .rollingBackPartialNew
            )
        }
        try repository.finishNotionPageSyncRollback(
            meetingID: meetingID,
            contentRevision: contentRevision
        )
    }

    private func cleanOldPageBlocks(
        meetingID: UUID,
        contentRevision: Int
    ) async throws {
        let run = try repository.meeting(id: meetingID)
            .archiveCheckpoint?.pageSyncRun()
        guard let run,
              run.contentRevision == contentRevision,
              run.phase == .cleaningOld else {
            throw MeetingDocumentRepositoryError.invalidNotionPageSyncRun
        }
        for blockID in run.oldBlockIDs {
            try await client.archiveBlock(id: blockID)
            try repository.recordNotionPageSyncBlockRemoval(
                meetingID: meetingID,
                contentRevision: contentRevision,
                blockID: blockID,
                phase: .cleaningOld
            )
        }
        try repository.completeNotionPageSyncRun(
            meetingID: meetingID,
            contentRevision: contentRevision
        )
    }

    private func allChildBlockIDs(pageID: String) async throws -> [String] {
        var result: [String] = []
        var seenBlockIDs: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?

        while true {
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw NotionClientError.invalidResponse
            }
            let page = try await client.childBlocks(
                pageID: pageID,
                startCursor: cursor
            )
            for blockID in page.blockIDs {
                let canonical = blockID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !canonical.isEmpty,
                      canonical == blockID,
                      seenBlockIDs.insert(canonical).inserted else {
                    throw NotionClientError.invalidResponse
                }
                result.append(canonical)
            }
            guard let nextCursor = page.nextCursor else { return result }
            let canonicalCursor = nextCursor.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !canonicalCursor.isEmpty,
                  canonicalCursor == nextCursor else {
                throw NotionClientError.invalidResponse
            }
            cursor = canonicalCursor
        }
    }

    private func encodePageSnapshot(
        _ content: NotionMeetingPageContent
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(content)
        } catch {
            throw ArchiveCheckpointCodingError.encodingFailed(
                "pageSyncSnapshotData"
            )
        }
    }

    private func decodePageSnapshot(
        _ data: Data
    ) throws -> NotionMeetingPageContent {
        do {
            return try JSONDecoder().decode(
                NotionMeetingPageContent.self,
                from: data
            )
        } catch {
            throw ArchiveCheckpointCodingError.invalidData(
                "pageSyncSnapshotData"
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
