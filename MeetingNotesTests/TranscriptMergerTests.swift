import XCTest
@testable import MeetingNotes

final class TranscriptMergerTests: XCTestCase {
    func testRemovesRepeatedBoundaryTextAndPreservesTimestamps() {
        let drafts = [
            TranscriptDraft(startTime: 0, endTime: 8, text: "今天讨论发布计划"),
            TranscriptDraft(startTime: 7, endTime: 15, text: "发布计划明天执行")
        ]

        let merged = TranscriptMerger().merge(drafts)

        XCTAssertEqual(merged.map(\.text), ["今天讨论发布计划", "明天执行"])
        XCTAssertEqual(merged.map(\.startTime), [0, 7])
        XCTAssertEqual(merged.map(\.endTime), [8, 15])
    }

    func testSortsDraftsAndDropsFullyDuplicatedOrBlankBoundaries() {
        let drafts = [
            TranscriptDraft(startTime: 10, endTime: 15, text: "继续执行"),
            TranscriptDraft(startTime: 4, endTime: 10, text: "项目启动"),
            TranscriptDraft(startTime: 9, endTime: 11, text: "项目启动"),
            TranscriptDraft(startTime: 16, endTime: 17, text: "  ")
        ]

        let merged = TranscriptMerger().merge(drafts)

        XCTAssertEqual(merged.map(\.text), ["项目启动", "继续执行"])
        XCTAssertEqual(merged.map(\.startTime), [4, 10])
        XCTAssertEqual(merged.map(\.endTime), [10, 15])
    }

    func testDoesNotRemoveIncidentalSingleCharacterOverlap() {
        let drafts = [
            TranscriptDraft(startTime: 0, endTime: 2, text: "先确定"),
            TranscriptDraft(startTime: 2, endTime: 4, text: "定方案")
        ]

        XCTAssertEqual(
            TranscriptMerger().merge(drafts).map(\.text),
            ["先确定", "定方案"]
        )
    }
}
