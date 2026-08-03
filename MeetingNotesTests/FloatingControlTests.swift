import AppKit
import XCTest
@testable import MeetingNotes

final class FloatingControlTests: XCTestCase {
    func testFloatingPanelHasExactlyFourControlsInRequiredOrder() {
        XCTAssertEqual(
            FloatingControl.allCases,
            [.record, .pause, .stop, .bookmark]
        )
    }

    func testEachControlHasAUniqueValidSymbolAndVoiceOverLabel() {
        let presentations = FloatingControl.allCases.map {
            $0.presentation(isPaused: false)
        }

        XCTAssertEqual(Set(presentations.map(\.symbolName)).count, 4)
        XCTAssertEqual(Set(presentations.map(\.accessibilityLabel)).count, 4)
        XCTAssertTrue(
            presentations.allSatisfy {
                NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil)
                    != nil
            }
        )
        XCTAssertTrue(
            presentations.allSatisfy { !$0.accessibilityLabel.isEmpty }
        )
    }

    func testPausedStateReusesPauseControlAsResumeWithoutAddingAFifthControl() {
        let active = FloatingControl.pause.presentation(isPaused: false)
        let paused = FloatingControl.pause.presentation(isPaused: true)

        XCTAssertEqual(active.symbolName, "pause.fill")
        XCTAssertEqual(active.accessibilityLabel, "暂停")
        XCTAssertEqual(paused.symbolName, "play.fill")
        XCTAssertEqual(paused.accessibilityLabel, "继续")
        XCTAssertEqual(FloatingControl.allCases.count, 4)
    }

    @MainActor
    func testRecorderViewSourcesButtonsOnlyFromFloatingControlCases() {
        let presentation = RecordingSessionPresentationStore()
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            action: { _ in }
        )

        XCTAssertEqual(view.controls, FloatingControl.allCases)
    }

    @MainActor
    func testRecorderViewFormatsSharedLiveElapsedTime() async {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            action: { _ in }
        )

        XCTAssertEqual(view.elapsedText(at: 165), "01:05")
    }

    @MainActor
    func testRecorderViewMarksPausedPresentationAsPaused() async {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        await presentation.pause(meetingID: meetingID, activeDuration: 5)
        let view = FloatingRecorderView(
            isPaused: true,
            recordingPresentationStore: presentation,
            action: { _ in }
        )

        XCTAssertEqual(view.statusAccessibilityLabel, "录音已暂停")
        XCTAssertEqual(view.elapsedText(at: 500), "00:05")
    }

    @MainActor
    func testPanelUsesNonactivatingFloatingAllSpacesConfiguration() {
        let suiteName = "FloatingControlTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = FloatingPanelController(
            defaults: defaults,
            recordingPresentationStore: RecordingSessionPresentationStore(),
            action: { _ in }
        )
        let panel = controller.panel

        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @MainActor
    func testPanelReusesHostingViewAcrossPauseAndRepeatVisibilityCycles() {
        let suiteName = "FloatingPanelReuseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = FloatingPanelController(
            defaults: defaults,
            animationDuration: 0,
            reduceMotion: { false },
            recordingPresentationStore: RecordingSessionPresentationStore(),
            action: { _ in }
        )
        let contentView = controller.panel.contentView

        controller.show()
        XCTAssertTrue(controller.panel.isVisible)
        controller.setPaused(true)
        XCTAssertTrue(controller.panel.contentView === contentView)
        controller.hide()
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1)

        controller.show()
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        controller.hide()
    }

    func testPositionStoreRoundTripsPanelOrigin() {
        let suiteName = "FloatingPanelPositionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FloatingPanelPositionStore(defaults: defaults)
        let origin = CGPoint(x: 321.5, y: 654.25)

        store.save(origin)

        XCTAssertEqual(store.load(), origin)
    }
}
