import AppKit
import XCTest
@testable import MeetingNotes

final class FloatingControlTests: XCTestCase {
    func testFloatingPanelHasExactlySixControlsInRequiredOrder() {
        XCTAssertEqual(
            FloatingControl.allCases,
            [.record, .pause, .stop, .bookmark, .note, .screenshot]
        )
    }

    func testEachControlHasAUniqueValidSymbolAndVoiceOverLabel() {
        let presentations = FloatingControl.allCases.map {
            $0.presentation(isPaused: false)
        }

        XCTAssertEqual(Set(presentations.map(\.symbolName)).count, 6)
        XCTAssertEqual(Set(presentations.map(\.accessibilityLabel)).count, 6)
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

    func testPausedStateReusesPauseControlAsResumeWithoutAddingAControl() {
        let active = FloatingControl.pause.presentation(isPaused: false)
        let paused = FloatingControl.pause.presentation(isPaused: true)

        XCTAssertEqual(active.symbolName, "pause.fill")
        XCTAssertEqual(active.accessibilityLabel, "暂停")
        XCTAssertEqual(paused.symbolName, "play.fill")
        XCTAssertEqual(paused.accessibilityLabel, "继续")
        XCTAssertEqual(FloatingControl.allCases.count, 6)
    }

    @MainActor
    func testRecorderViewSourcesButtonsOnlyFromFloatingControlCases() {
        let presentation = RecordingSessionPresentationStore()
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )

        XCTAssertEqual(view.controls, FloatingControl.allCases)
    }

    @MainActor
    func testRecorderViewFormatsSharedLiveElapsedTime() async {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
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
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let view = FloatingRecorderView(
            isPaused: true,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )

        XCTAssertEqual(view.statusAccessibilityLabel, "录音已暂停")
        XCTAssertEqual(view.elapsedText(at: 500), "00:05")
    }

    @MainActor
    func testStopRemainsEnabledWhileEnteringANote() async throws {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let context = makeAnnotationContext(
            presentation: presentation,
            meetingID: meetingID
        )
        defer { context.remove() }
        context.viewModel.beginNote()
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )

        XCTAssertTrue(context.viewModel.isNoteEditorPresented)
        XCTAssertTrue(view.isControlEnabled(.stop))
    }

    @MainActor
    func testEnterFlushesDraftBeforeEditorCollapses() async throws {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let context = makeAnnotationContext(
            presentation: presentation,
            meetingID: meetingID
        )
        defer { context.remove() }
        context.viewModel.beginNote()
        context.viewModel.updateNoteDraft("当场记录")
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )

        await view.submitNote()

        XCTAssertFalse(context.viewModel.isNoteEditorPresented)
        XCTAssertEqual(
            try context.repository.notes(meetingID: meetingID).first?.text,
            "当场记录"
        )
    }

    @MainActor
    func testPanelUsesNonactivatingFloatingAllSpacesConfiguration() {
        let suiteName = "FloatingControlTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presentation = RecordingSessionPresentationStore()
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let controller = FloatingPanelController(
            defaults: defaults,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
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
        let presentation = RecordingSessionPresentationStore()
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let controller = FloatingPanelController(
            defaults: defaults,
            animationDuration: 0,
            reduceMotion: { false },
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
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

    @MainActor
    func testPanelResizesWithoutReplacingHostingView() {
        let suiteName = "FloatingPanelResizeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presentation = RecordingSessionPresentationStore()
        let context = makeAnnotationContext(presentation: presentation)
        defer { context.remove() }
        let controller = FloatingPanelController(
            defaults: defaults,
            animationDuration: 0,
            reduceMotion: { false },
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )
        let contentView = controller.panel.contentView
        let compactFrame = controller.panel.frame

        controller.setNoteEditorPresented(true)

        XCTAssertTrue(controller.panel.contentView === contentView)
        XCTAssertEqual(controller.panel.frame.width, compactFrame.width)
        XCTAssertGreaterThan(controller.panel.frame.height, compactFrame.height)

        controller.setNoteEditorPresented(false)
        XCTAssertTrue(controller.panel.contentView === contentView)
        XCTAssertEqual(controller.panel.frame.size, compactFrame.size)
    }

    func testPanelSizePolicyAccountsForScreenshotFeedbackAndNoteEditor() {
        XCTAssertEqual(
            FloatingPanelSizePolicy.size(
                noteEditorPresented: false,
                screenshotFeedbackPresented: false
            ),
            FloatingPanelSizePolicy.compact
        )
        XCTAssertEqual(
            FloatingPanelSizePolicy.size(
                noteEditorPresented: true,
                screenshotFeedbackPresented: false
            ),
            FloatingPanelSizePolicy.noteEditor
        )
        XCTAssertGreaterThan(
            FloatingPanelSizePolicy.size(
                noteEditorPresented: false,
                screenshotFeedbackPresented: true
            ).height,
            FloatingPanelSizePolicy.compact.height
        )
        XCTAssertGreaterThan(
            FloatingPanelSizePolicy.size(
                noteEditorPresented: true,
                screenshotFeedbackPresented: true
            ).height,
            FloatingPanelSizePolicy.noteEditor.height
        )
    }

    @MainActor
    func testPermissionFailureIsExposedAsNonblockingFloatingFeedback() async {
        let meetingID = UUID()
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let context = makeAnnotationContext(
            presentation: presentation,
            meetingID: meetingID,
            screenshotCapture: FloatingFailingScreenshotCapture()
        )
        defer { context.remove() }

        await context.viewModel.captureScreenshot()
        let view = FloatingRecorderView(
            isPaused: false,
            recordingPresentationStore: presentation,
            annotationViewModel: context.viewModel,
            action: { _ in }
        )

        XCTAssertTrue(view.isScreenshotFeedbackPresented)
        XCTAssertEqual(context.viewModel.screenshotState, .permissionRequired)
        XCTAssertEqual(presentation.phase, .recording)
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

    @MainActor
    private func makeAnnotationContext(
        presentation: RecordingSessionPresentationStore,
        meetingID: UUID? = nil,
        screenshotCapture: any MeetingScreenshotCapturing =
            FloatingScreenshotCaptureStub()
    ) -> FloatingAnnotationTestContext {
        let repository = try! MeetingRepository.inMemory()
        if let meetingID {
            _ = try! repository.createMeeting(
                id: meetingID,
                mode: .offline,
                startedAt: Date(timeIntervalSince1970: 1)
            )
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FloatingControlTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: MeetingFileStore(rootURL: root),
            screenshotCapture: screenshotCapture,
            presentationStore: presentation,
            monotonicTime: { 104 }
        )
        return FloatingAnnotationTestContext(
            root: root,
            repository: repository,
            viewModel: viewModel
        )
    }
}

private struct FloatingAnnotationTestContext {
    let root: URL
    let repository: MeetingRepository
    let viewModel: RecordingAnnotationViewModel

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FloatingScreenshotCaptureStub: MeetingScreenshotCapturing {
    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        MeetingScreenshotCaptureResult(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            pixelWidth: 100,
            pixelHeight: 100
        )
    }
}

private struct FloatingFailingScreenshotCapture: MeetingScreenshotCapturing {
    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        throw MeetingScreenshotCaptureError.screenRecordingDenied
    }
}
