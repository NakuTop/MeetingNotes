import AppKit
import XCTest
@testable import MeetingNotes

final class MeetingNotionArchiveDisplayStateTests: XCTestCase {
    func testNoArchivedDocumentIsNotArchived() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: .localOnly,
                detailedMinutes: .failed,
                legacyMeetingState: .summaryReady,
                hasNotionPage: true
            ),
            .none
        )
    }

    func testDetailedMinutesArchiveMakesMixedMeetingPartiallyArchived() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: .localOnly,
                detailedMinutes: .archived,
                legacyMeetingState: .summaryReady,
                hasNotionPage: true
            ),
            .partial
        )
    }

    func testEveryExistingArchivedDocumentIsComplete() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: .archived,
                detailedMinutes: .archived,
                legacyMeetingState: .archived,
                hasNotionPage: true
            ),
            .complete
        )
    }

    func testSingleExistingArchivedDocumentIsComplete() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: nil,
                detailedMinutes: .archived,
                legacyMeetingState: .summaryReady,
                hasNotionPage: true
            ),
            .complete
        )
    }

    func testLegacyArchivedMeetingWithNotionPageRemainsComplete() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: nil,
                detailedMinutes: nil,
                legacyMeetingState: .archived,
                hasNotionPage: true
            ),
            .complete
        )
    }

    func testEmptyLegacyMeetingWithoutNotionPageIsNotArchived() {
        XCTAssertEqual(
            MeetingNotionArchiveDisplayState.resolve(
                summary: nil,
                detailedMinutes: nil,
                legacyMeetingState: .archived,
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
            (.none, "icloud.slash", "未归档到 Notion"),
            (.partial, "checkmark.icloud", "部分内容已归档到 Notion"),
            (.complete, "checkmark.icloud.fill", "全部内容已归档到 Notion"),
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
}
