import XCTest
@testable import MeetingNotes

final class TranscriptDisclosurePolicyTests: XCTestCase {
    func testStartsExpandedBeforeSummaryExists() {
        XCTAssertTrue(
            TranscriptDisclosurePolicy.initialIsExpanded(hasSummary: false)
        )
    }

    func testStartsCollapsedWhenSummaryAlreadyExists() {
        XCTAssertFalse(
            TranscriptDisclosurePolicy.initialIsExpanded(hasSummary: true)
        )
    }

    func testNewSummaryCollapsesBeforeUserInteraction() {
        XCTAssertTrue(
            TranscriptDisclosurePolicy.shouldCollapse(
                previouslyHadSummary: false,
                hasSummary: true,
                userHasInteracted: false
            )
        )
    }

    func testNewSummaryDoesNotCollapseAfterUserInteraction() {
        XCTAssertFalse(
            TranscriptDisclosurePolicy.shouldCollapse(
                previouslyHadSummary: false,
                hasSummary: true,
                userHasInteracted: true
            )
        )
    }
}
