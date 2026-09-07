import XCTest
@testable import MeetingNotes

final class MeetingDocumentModeSliderDragPolicyTests: XCTestCase {
    func testTapAnywhereInLeftHalfSelectsSummary() {
        for locationX in [0, 1, 24, 49] as [CGFloat] {
            XCTAssertEqual(
                MeetingDocumentModeSliderTapPolicy.selection(
                    currentSelection: .detailedMinutes,
                    locationX: locationX,
                    width: 100,
                    isDisabled: false
                ),
                .summary
            )
        }
    }

    func testTapAnywhereInRightHalfSelectsDetailedMinutes() {
        for locationX in [51, 75, 99, 100] as [CGFloat] {
            XCTAssertEqual(
                MeetingDocumentModeSliderTapPolicy.selection(
                    currentSelection: .summary,
                    locationX: locationX,
                    width: 100,
                    isDisabled: false
                ),
                .detailedMinutes
            )
        }
    }

    func testTapAtExactMidpointKeepsCurrentSelection() {
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .summary,
                locationX: 50,
                width: 100,
                isDisabled: false
            ),
            .summary
        )
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .detailedMinutes,
                locationX: 50,
                width: 100,
                isDisabled: false
            ),
            .detailedMinutes
        )
    }

    func testDisabledOrInvalidTapKeepsCurrentSelection() {
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .summary,
                locationX: 75,
                width: 100,
                isDisabled: true
            ),
            .summary
        )
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .detailedMinutes,
                locationX: -1,
                width: 100,
                isDisabled: false
            ),
            .detailedMinutes
        )
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .summary,
                locationX: 101,
                width: 100,
                isDisabled: false
            ),
            .summary
        )
        XCTAssertEqual(
            MeetingDocumentModeSliderTapPolicy.selection(
                currentSelection: .summary,
                locationX: 25,
                width: 0,
                isDisabled: false
            ),
            .summary
        )
    }

    func testLeftToRightCrossingSelectsDetailedMinutes() {
        let update = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: 75,
            width: 100
        )

        XCTAssertEqual(update.selection, .detailedMinutes)
        XCTAssertEqual(update.dragOffset, 0, accuracy: 0.001)
    }

    func testRightToLeftCrossingSelectsSummary() {
        let update = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .detailedMinutes,
            locationX: 25,
            width: 100
        )

        XCTAssertEqual(update.selection, .summary)
        XCTAssertEqual(update.dragOffset, 0, accuracy: 0.001)
    }

    func testCrossingThenDraggingBackRestoresStartingSelection() {
        let crossed = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: 51,
            width: 100
        )
        let draggedBack = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: 49,
            width: 100
        )

        XCTAssertEqual(crossed.selection, .detailedMinutes)
        XCTAssertEqual(crossed.dragOffset, -24, accuracy: 0.001)
        XCTAssertEqual(draggedBack.selection, .summary)
        XCTAssertEqual(draggedBack.dragOffset, 24, accuracy: 0.001)
    }

    func testExactMidpointKeepsGestureStartingSelection() {
        let fromSummary = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: 50,
            width: 100
        )
        let fromDetailed = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .detailedMinutes,
            locationX: 50,
            width: 100
        )

        XCTAssertEqual(fromSummary.selection, .summary)
        XCTAssertEqual(fromDetailed.selection, .detailedMinutes)
    }

    func testOffsetsFollowCurrentHalfAndClampAwayFromOuterEdges() {
        let summaryOutward = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: -50,
            width: 100
        )
        let summaryTowardMiddle = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .summary,
            locationX: 49,
            width: 100
        )
        let detailedTowardMiddle = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .detailedMinutes,
            locationX: 51,
            width: 100
        )
        let detailedOutward = MeetingDocumentModeSliderDragPolicy.update(
            startingSelection: .detailedMinutes,
            locationX: 150,
            width: 100
        )

        XCTAssertEqual(summaryOutward.dragOffset, 0, accuracy: 0.001)
        XCTAssertEqual(summaryTowardMiddle.selection, .summary)
        XCTAssertEqual(summaryTowardMiddle.dragOffset, 24, accuracy: 0.001)
        XCTAssertEqual(detailedTowardMiddle.selection, .detailedMinutes)
        XCTAssertEqual(detailedTowardMiddle.dragOffset, -24, accuracy: 0.001)
        XCTAssertEqual(detailedOutward.dragOffset, 0, accuracy: 0.001)
    }
}
