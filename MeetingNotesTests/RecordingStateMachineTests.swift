import XCTest
@testable import MeetingNotes

final class RecordingStateMachineTests: XCTestCase {
    func testCompleteRecordingSummaryAndArchiveLifecycle() throws {
        var machine = RecordingStateMachine()

        try machine.send(.prepare)
        XCTAssertEqual(machine.state, .preparing)

        try machine.send(.start)
        XCTAssertEqual(machine.state, .recording)

        try machine.send(.bookmark)
        XCTAssertEqual(machine.state, .recording)

        try machine.send(.pause)
        XCTAssertEqual(machine.state, .paused)

        try machine.send(.bookmark)
        XCTAssertEqual(machine.state, .paused)

        try machine.send(.resume)
        XCTAssertEqual(machine.state, .recording)

        try machine.send(.stop)
        XCTAssertEqual(machine.state, .finalizing)

        try machine.send(.finalized)
        XCTAssertEqual(machine.state, .ready)

        try machine.send(.summarize)
        XCTAssertEqual(machine.state, .summarizing)

        try machine.send(.summarySucceeded)
        XCTAssertEqual(machine.state, .summaryReady)

        try machine.send(.archive)
        XCTAssertEqual(machine.state, .archiving)

        try machine.send(.archiveSucceeded)
        XCTAssertEqual(machine.state, .archived)
    }

    func testPausedRecordingCanBeStopped() throws {
        var machine = RecordingStateMachine(state: .paused)

        try machine.send(.stop)

        XCTAssertEqual(machine.state, .finalizing)
    }

    func testSummaryFailureReturnsToReady() throws {
        var machine = RecordingStateMachine(state: .summarizing)

        try machine.send(.summaryFailed)

        XCTAssertEqual(machine.state, .ready)
    }

    func testArchiveFailureReturnsToSummaryReady() throws {
        var machine = RecordingStateMachine(state: .archiving)

        try machine.send(.archiveFailed)

        XCTAssertEqual(machine.state, .summaryReady)
    }

    func testCannotBookmarkWhenIdle() {
        var machine = RecordingStateMachine()

        XCTAssertThrowsError(try machine.send(.bookmark)) { error in
            XCTAssertEqual(
                error as? RecordingStateError,
                .invalidTransition(.idle, .bookmark)
            )
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testInvalidTransitionPreservesStateAndReportsAction() {
        var machine = RecordingStateMachine(state: .archived)

        XCTAssertThrowsError(try machine.send(.start)) { error in
            XCTAssertEqual(
                error as? RecordingStateError,
                .invalidTransition(.archived, .start)
            )
        }
        XCTAssertEqual(machine.state, .archived)
    }

    func testEveryStateAndActionPairHasAnExplicitOutcome() throws {
        for state in RecordingState.allCases {
            for action in RecordingAction.allCases {
                var machine = RecordingStateMachine(state: state)

                if let expectedState = expectedState(from: state, action: action) {
                    try machine.send(action)
                    XCTAssertEqual(
                        machine.state,
                        expectedState,
                        "Unexpected result for \(state.rawValue) + \(action.rawValue)"
                    )
                } else {
                    XCTAssertThrowsError(try machine.send(action)) { error in
                        XCTAssertEqual(
                            error as? RecordingStateError,
                            .invalidTransition(state, action),
                            "Unexpected error for \(state.rawValue) + \(action.rawValue)"
                        )
                    }
                    XCTAssertEqual(machine.state, state)
                }
            }
        }
    }

    func testStateAndActionUseStableCodableRawValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encodedState = try encoder.encode(RecordingState.summaryReady)
        let encodedAction = try encoder.encode(RecordingAction.archiveSucceeded)

        XCTAssertEqual(
            try decoder.decode(RecordingState.self, from: encodedState),
            .summaryReady
        )
        XCTAssertEqual(
            try decoder.decode(RecordingAction.self, from: encodedAction),
            .archiveSucceeded
        )
        XCTAssertEqual(String(data: encodedState, encoding: .utf8), "\"summaryReady\"")
        XCTAssertEqual(String(data: encodedAction, encoding: .utf8), "\"archiveSucceeded\"")
    }

    private func expectedState(
        from state: RecordingState,
        action: RecordingAction
    ) -> RecordingState? {
        switch (state, action) {
        case (.idle, .prepare):
            .preparing
        case (.preparing, .start):
            .recording
        case (.recording, .pause):
            .paused
        case (.paused, .resume):
            .recording
        case (.recording, .stop), (.paused, .stop):
            .finalizing
        case (.finalizing, .finalized):
            .ready
        case (.recording, .bookmark):
            .recording
        case (.paused, .bookmark):
            .paused
        case (.ready, .summarize):
            .summarizing
        case (.summarizing, .summarySucceeded):
            .summaryReady
        case (.summarizing, .summaryFailed):
            .ready
        case (.summaryReady, .archive):
            .archiving
        case (.archiving, .archiveSucceeded):
            .archived
        case (.archiving, .archiveFailed):
            .summaryReady
        default:
            nil
        }
    }
}
