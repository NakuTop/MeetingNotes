import AppKit
import XCTest
@testable import MeetingNotes

final class MeetingNotionArchiveDisplayStateTests: XCTestCase {
    func testCanonicalMeetingSyncOverridesLegacyPerDocumentStates() {
        XCTAssertEqual(
            resolve(
                syncState: .synced,
                contentRevision: 7,
                syncedContentRevision: 7,
                summary: .archived,
                detailedMinutes: .localOnly
            ),
            .complete
        )
    }

    func testNewerLocalRevisionIsDirtyAfterEarlierSync() {
        XCTAssertEqual(
            resolve(
                syncState: .localOnly,
                contentRevision: 8,
                syncedContentRevision: 7
            ),
            .dirty
        )
    }

    func testMeetingSyncingAndFailureRemainDistinct() {
        XCTAssertEqual(resolve(syncState: .syncing), .syncing)
        XCTAssertEqual(resolve(syncState: .failed), .failed)
    }

    func testFirstUnsyncedMeetingHasNoSyncIndicator() {
        XCTAssertEqual(
            resolve(
                syncState: .localOnly,
                contentRevision: 3,
                syncedContentRevision: nil
            ),
            .none
        )
    }

    func testSyncedStateWithoutMatchingRevisionIsNotComplete() {
        XCTAssertEqual(
            resolve(
                syncState: .synced,
                contentRevision: 4,
                syncedContentRevision: 3
            ),
            .dirty
        )
        XCTAssertEqual(
            resolve(
                syncState: .synced,
                contentRevision: 4,
                syncedContentRevision: nil
            ),
            .none
        )
    }

    func testLegacyRecordsWithoutMeetingSyncStateKeepArchiveMeaning() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                notionSyncStateRawValue: nil,
                contentRevision: 0,
                syncedContentRevision: nil,
                summary: .localOnly,
                detailedMinutes: .archived,
                legacyMeetingState: .summaryReady,
                hasNotionPage: true
            ),
            .dirty
        )
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                notionSyncStateRawValue: nil,
                contentRevision: 0,
                syncedContentRevision: nil,
                summary: nil,
                detailedMinutes: nil,
                legacyMeetingState: .archived,
                hasNotionPage: true
            ),
            .complete
        )
    }

    func testNoNotionPageCanNeverAppearSynced() {
        XCTAssertEqual(
            resolve(
                syncState: .synced,
                contentRevision: 7,
                syncedContentRevision: 7,
                hasNotionPage: false
            ),
            .none
        )
    }

    func testEveryDisplayStateUsesValidSymbolAndExactAccessibilityLabel() {
        let cases: [(
            MeetingNotionArchiveDisplayState,
            symbol: String,
            label: String
        )] = [
            (.none, "icloud.slash", "尚未同步到 Notion"),
            (.dirty, "icloud.and.arrow.up", "有本地更改待同步到 Notion"),
            (.syncing, "arrow.triangle.2.circlepath.icloud", "正在同步到 Notion"),
            (.failed, "exclamationmark.icloud", "同步到 Notion 失败"),
            (.complete, "checkmark.icloud.fill", "已同步到 Notion"),
        ]

        for (state, symbol, label) in cases {
            XCTAssertEqual(state.symbolName, symbol)
            XCTAssertEqual(state.accessibilityLabel, label)
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: symbol,
                    accessibilityDescription: nil
                )
            )
        }
    }

    private func resolve(
        syncState: MeetingNotionSyncState,
        contentRevision: Int = 1,
        syncedContentRevision: Int? = nil,
        summary: MeetingDocumentArchiveState? = .localOnly,
        detailedMinutes: MeetingDocumentArchiveState? = nil,
        hasNotionPage: Bool = true
    ) -> MeetingNotionArchiveDisplayState {
        MeetingNotionArchiveDisplayState.resolve(
            notionSyncStateRawValue: syncState.rawValue,
            contentRevision: contentRevision,
            syncedContentRevision: syncedContentRevision,
            summary: summary,
            detailedMinutes: detailedMinutes,
            legacyMeetingState: .summaryReady,
            hasNotionPage: hasNotionPage
        )
    }
}
