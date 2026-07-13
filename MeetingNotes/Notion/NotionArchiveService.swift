import Foundation

@MainActor
final class NotionArchiveService {
    private let repository: MeetingRepository
    private let client: any NotionAPIClient
    private let blockBuilder: NotionBlockBuilder

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
        let meeting = try repository.meeting(id: meetingID)
        let page: NotionPageReference
        if let existingPageID = meeting.notionPageID {
            page = NotionPageReference(
                id: existingPageID,
                url: meeting.notionPageURL ?? Self.fallbackURL(for: existingPageID)
            )
        } else {
            page = try await client.createPage(
                parentPageID: parentPageID,
                title: content.summary.suggestedTitle
            )
            try repository.setNotionPage(
                meetingID: meetingID,
                pageID: page.id,
                pageURL: page.url
            )
            try repository.saveArchiveCheckpoint(
                meetingID: meetingID,
                notionPageID: page.id,
                nextSection: "blocks",
                nextBatchIndex: 0
            )
        }

        let batches = blockBuilder.batches(for: content)
        let refreshedMeeting = try repository.meeting(id: meetingID)
        let checkpoint = refreshedMeeting.archiveCheckpoint
        let startIndex: Int
        if let checkpoint,
           checkpoint.notionPageID == page.id {
            startIndex = min(max(0, checkpoint.nextBatchIndex), batches.count)
        } else {
            startIndex = 0
            try repository.saveArchiveCheckpoint(
                meetingID: meetingID,
                notionPageID: page.id,
                nextSection: "blocks",
                nextBatchIndex: 0
            )
        }

        for index in startIndex..<batches.count {
            try await client.append(blocks: batches[index], to: page.id)
            let nextIndex = index + 1
            try repository.saveArchiveCheckpoint(
                meetingID: meetingID,
                notionPageID: page.id,
                nextSection: nextIndex == batches.count ? "complete" : "blocks",
                nextBatchIndex: nextIndex
            )
        }

        if startIndex == batches.count {
            try repository.saveArchiveCheckpoint(
                meetingID: meetingID,
                notionPageID: page.id,
                nextSection: "complete",
                nextBatchIndex: batches.count
            )
        }
        return page
    }

    private static func fallbackURL(for pageID: String) -> String {
        "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))"
    }
}
