import AppKit
import CoreGraphics
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingScreenshotWindowPickerTests: XCTestCase {
    private let mainDisplay = MeetingScreenshotDisplayGeometry(
        cocoaFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        quartzFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    )
    private let ownProcessID: pid_t = 100

    func testHighlightedInteriorKeepsANearlyClearInputSurface() throws {
        let view = MeetingScreenshotSelectionView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        view.targetRect = CGRect(x: 20, y: 20, width: 60, height: 60)

        let bitmap = try drawOffscreen(view)
        let interior = try XCTUnwrap(bitmap.colorAt(x: 50, y: 50))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 5, y: 50))

        // A zero-alpha hole can send clicks to the app below the NSPanel,
        // before our NSView.hitTest/mouseDown gets a chance to select it.
        XCTAssertGreaterThanOrEqual(interior.alphaComponent, 0.01)
        XCTAssertLessThanOrEqual(interior.alphaComponent, 0.03)
        XCTAssertGreaterThan(outside.alphaComponent, 0.15)
        XCTAssertLessThan(outside.alphaComponent, 0.20)
        XCTAssertNil(view.window, "This test must never create or show a window")
    }

    func testRepeatedHighlightDrawingDoesNotAccumulateDimming() throws {
        let view = MeetingScreenshotSelectionView(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        view.targetRect = CGRect(x: 20, y: 20, width: 60, height: 60)
        let once = try drawOffscreen(view)
        let repeated = try drawOffscreen(view, count: 8)

        for point in [(50, 50), (5, 50)] {
            let first = try XCTUnwrap(once.colorAt(x: point.0, y: point.1))
            let last = try XCTUnwrap(repeated.colorAt(x: point.0, y: point.1))
            XCTAssertEqual(first.alphaComponent, last.alphaComponent, accuracy: 1.0 / 255)
        }
        XCTAssertNil(view.window)
    }

    func testMovingAndClearingHighlightRepaintsTheInputSurface() throws {
        let previous = CGRect(x: 10, y: 35, width: 30, height: 30)
        let next = CGRect(x: 60, y: 35, width: 30, height: 30)
        for finalTarget: CGRect? in [next, nil] {
            let view = MeetingScreenshotSelectionView(
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
            let bitmap = try drawOffscreen(view, count: 2) { index in
                view.targetRect = index == 0 ? previous : finalTarget
            }
            let oldInterior = try XCTUnwrap(bitmap.colorAt(x: 25, y: 50))
            let newInterior = try XCTUnwrap(bitmap.colorAt(x: 75, y: 50))
            XCTAssertGreaterThan(oldInterior.alphaComponent, 0.15)
            XCTAssertLessThan(oldInterior.alphaComponent, 0.20)
            if finalTarget != nil {
                XCTAssertGreaterThanOrEqual(newInterior.alphaComponent, 0.01)
                XCTAssertLessThanOrEqual(newInterior.alphaComponent, 0.03)
            } else {
                XCTAssertGreaterThan(newInterior.alphaComponent, 0.15)
                XCTAssertLessThan(newInterior.alphaComponent, 0.20)
            }
            XCTAssertNil(view.window)
        }
    }

    private func drawOffscreen(
        _ view: MeetingScreenshotSelectionView, count: Int = 1,
        beforeDraw: (Int) -> Void = { _ in }
    ) throws -> NSBitmapImageRep {
        // Draw only our overlay into a fresh in-memory bitmap: no Window
        // Server surface, real screenshots, cursor movement, or input events.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(view.bounds)
        for index in 0..<count {
            beforeDraw(index)
            view.draw(view.bounds)
        }
        return bitmap
    }

    func testCoordinatesUseEachPairedDisplayForEveryMonitorPlacement() {
        let examples: [(MeetingScreenshotDisplayGeometry, CGPoint, CGPoint)] = [
            (mainDisplay, CGPoint(x: 250, y: 700), CGPoint(x: 250, y: 380)),
            (.init(
                cocoaFrame: CGRect(x: 0, y: 1_080, width: 1_280, height: 800),
                quartzFrame: CGRect(x: 0, y: -800, width: 1_280, height: 800)
            ), CGPoint(x: 200, y: 1_500), CGPoint(x: 200, y: -420)),
            (.init(
                cocoaFrame: CGRect(x: 0, y: -900, width: 1_440, height: 900),
                quartzFrame: CGRect(x: 0, y: 1_080, width: 1_440, height: 900)
            ), CGPoint(x: 400, y: -600), CGPoint(x: 400, y: 1_680)),
            (.init(
                cocoaFrame: CGRect(x: -1_440, y: 100, width: 1_440, height: 900),
                quartzFrame: CGRect(x: -1_440, y: 80, width: 1_440, height: 900)
            ), CGPoint(x: -800, y: 500), CGPoint(x: -800, y: 580)),
            (.init(
                cocoaFrame: CGRect(x: 1_920, y: -160, width: 1_600, height: 1_200),
                quartzFrame: CGRect(x: 1_920, y: 40, width: 1_600, height: 1_200)
            ), CGPoint(x: 2_500, y: 700), CGPoint(x: 2_500, y: 380)),
        ]
        let displays = examples.map(\.0)
        for (display, cocoa, quartz) in examples {
            XCTAssertEqual(
                MeetingScreenshotWindowCoordinates.quartzPoint(
                    fromCocoa: cocoa, displays: displays
                ), quartz, "Incorrect conversion for \(display)"
            )
        }
    }

    func testCoordinateConversionDoesNotUseTallestScreenAsOrigin() {
        let tallScreen = MeetingScreenshotDisplayGeometry(
            cocoaFrame: CGRect(x: -1_080, y: 500, width: 1_080, height: 1_920),
            quartzFrame: CGRect(x: -1_080, y: -1_340, width: 1_080, height: 1_920)
        )
        XCTAssertEqual(
            MeetingScreenshotWindowCoordinates.quartzPoint(
                fromCocoa: CGPoint(x: 100, y: 100),
                displays: [tallScreen, mainDisplay]
            ), CGPoint(x: 100, y: 980)
        )
    }

    func testOverlayRectClipsSpanningWindowIntoEachDisplayLocally() {
        let leftScreen = MeetingScreenshotDisplayGeometry(
            cocoaFrame: CGRect(x: -1_440, y: 100, width: 1_440, height: 900),
            quartzFrame: CGRect(x: -1_440, y: 80, width: 1_440, height: 900)
        )
        let window = CGRect(x: -120, y: 200, width: 400, height: 250)
        XCTAssertEqual(
            MeetingScreenshotWindowCoordinates.overlayRect(forQuartz: window, on: leftScreen),
            CGRect(x: 1_320, y: 530, width: 120, height: 250)
        )
        XCTAssertEqual(
            MeetingScreenshotWindowCoordinates.overlayRect(forQuartz: window, on: mainDisplay),
            CGRect(x: 0, y: 630, width: 280, height: 250)
        )
    }

    func testCoordinatesRejectGapsNonfinitePointsAndEmptyDisplays() {
        XCTAssertNil(MeetingScreenshotWindowCoordinates.quartzPoint(
            fromCocoa: CGPoint(x: 5_000, y: 5_000), displays: [mainDisplay]
        ))
        XCTAssertNil(MeetingScreenshotWindowCoordinates.quartzPoint(
            fromCocoa: CGPoint(x: CGFloat.infinity, y: 5), displays: [mainDisplay]
        ))
        XCTAssertNil(MeetingScreenshotWindowCoordinates.quartzPoint(
            fromCocoa: .zero, displays: []
        ))
        XCTAssertNil(MeetingScreenshotWindowCoordinates.overlayRect(
            forQuartz: .zero, on: mainDisplay
        ))
    }

    func testHitTestChoosesFrontmostEligibleWindowWithoutSortingByIDOrSize() {
        let front = window(id: 72, bounds: CGRect(x: 20, y: 20, width: 400, height: 300))
        let back = window(id: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
        XCTAssertEqual(hit([front, back], at: CGPoint(x: 100, y: 100)), front)
        XCTAssertEqual(hit([front, back], at: CGPoint(x: 600, y: 500)), back)
    }

    func testHitTestExcludesOwnAppDesktopMenusAndUnshareableWindows() {
        let target = window(id: 42)
        var own = window(id: 1)
        own = MeetingScreenshotWindowMetadata(
            windowID: own.windowID, processID: ownProcessID, bounds: own.bounds
        )
        var desktop = window(id: 2)
        desktop.layer = -2_147_483_600
        var menu = window(id: 3)
        menu.layer = 25
        var unshareable = window(id: 4)
        unshareable.isShareable = false
        XCTAssertEqual(hit([own, desktop, menu, unshareable, target]), target)
    }

    func testHitTestExcludesOffscreenInvisibleAndDegenerateWindows() {
        let target = window(id: 42)
        var hidden = window(id: 1)
        hidden.isOnScreen = false
        var transparent = window(id: 2)
        transparent.alpha = 0
        let empty = window(id: 3, bounds: .zero)
        let offscreen = window(id: 4, bounds: CGRect(x: -9_000, y: 0, width: 400, height: 300))
        let invalid = window(id: 5, bounds: CGRect(x: CGFloat.infinity, y: 0, width: 400, height: 300))
        XCTAssertEqual(hit([hidden, transparent, empty, offscreen, invalid, target]), target)
    }

    func testHitTestReturnsNilForEmptyAreaAndGapsBetweenDisplays() {
        XCTAssertNil(hit([window(id: 42)], at: CGPoint(x: 1_900, y: 1_000)))
        let offscreen = window(id: 2, bounds: CGRect(x: 3_000, y: 0, width: 400, height: 300))
        XCTAssertNil(hit([offscreen], at: CGPoint(x: 3_100, y: 100)))
        XCTAssertNil(hit([]))
    }

    func testClickAfterHoveredWindowDisappearsDoesNotSelectWindowBehindIt() {
        let front = window(id: 42)
        let back = window(id: 99)
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(hit([front, back]))

        let selected = intent.selectionForClick(refreshedWindow: hit([back]))

        XCTAssertNil(selected)
        XCTAssertEqual(intent.highlightedWindow, back)
    }

    func testClickAfterHoveredWindowMovesAwayDoesNotRetargetBehindIt() {
        let front = window(id: 42)
        let back = window(id: 99)
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(hit([front, back]))
        let moved = window(id: 42, bounds: CGRect(x: 700, y: 400, width: 400, height: 300))

        XCTAssertNil(intent.selectionForClick(refreshedWindow: hit([moved, back])))
        XCTAssertEqual(intent.highlightedWindow, back)
    }

    func testNewTargetNeedsAnotherClickAfterHighlightChanges() {
        let front = window(id: 42)
        let back = window(id: 99)
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(front)
        XCTAssertNil(intent.selectionForClick(refreshedWindow: back))

        XCTAssertEqual(intent.selectionForClick(refreshedWindow: back), back)
    }

    func testClickRejectsReusedWindowIDOwnedByDifferentProcess() {
        let original = window(id: 42)
        let replacement = MeetingScreenshotWindowMetadata(
            windowID: original.windowID, processID: 201, bounds: original.bounds
        )
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(original)

        XCTAssertNil(intent.selectionForClick(refreshedWindow: replacement))
        XCTAssertEqual(intent.highlightedWindow, replacement)
    }

    func testSameHoveredIdentityUsesFreshGeometryOnSingleClick() {
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(window(id: 42))
        let resized = window(id: 42, bounds: CGRect(x: 30, y: 40, width: 300, height: 200))

        XCTAssertEqual(intent.selectionForClick(refreshedWindow: resized), resized)
    }

    func testClickWithoutPriorHighlightedTargetDoesNotCapture() {
        var intent = MeetingScreenshotWindowSelectionIntent()
        let target = window(id: 42)

        XCTAssertNil(intent.selectionForClick(refreshedWindow: target))
        XCTAssertEqual(intent.highlightedWindow, target)
    }

    func testEmptyRefreshedHitClearsSelectionIntent() {
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(window(id: 42))

        XCTAssertNil(intent.selectionForClick(refreshedWindow: nil))
        XCTAssertNil(intent.highlightedWindow)
        XCTAssertNil(intent.selectionForClick(refreshedWindow: window(id: 99)))
    }

    func testNormalPointerMovementUpdatesExpectedTargetForSingleClick() {
        let target = window(id: 99)
        var intent = MeetingScreenshotWindowSelectionIntent()
        intent.updateHover(window(id: 42))
        intent.updateHover(target)

        XCTAssertEqual(intent.selectionForClick(refreshedWindow: target), target)
    }

    func testOneClickDismissesOverlayBeforeResolvingFreshWindow() async throws {
        let overlay = WindowPickerOverlayStub()
        let expected = selection()
        var events: [String] = []
        overlay.onPresent = { $0(.selected(self.window(id: 42))) }
        overlay.onDismiss = { events.append("dismiss") }
        let picker = makePicker(overlay: overlay) { metadata in
            events.append("resolve-\(metadata.windowID)")
            return expected
        }

        let result = try await picker.selectWindow()

        XCTAssertEqual(result, expected)
        XCTAssertEqual(events, ["dismiss", "resolve-42"])
        XCTAssertEqual(overlay.presentCount, 1)
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testEscapeReturnsNilAndDoesNotResolveOrCapture() async throws {
        let overlay = WindowPickerOverlayStub()
        overlay.onPresent = { $0(.cancelled) }
        var resolveCount = 0
        let picker = makePicker(overlay: overlay) { _ in
            resolveCount += 1
            return self.selection()
        }

        let result = try await picker.selectWindow()

        XCTAssertNil(result)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testFirstClickWinsOverDuplicateClickAndLateEscape() async throws {
        let overlay = WindowPickerOverlayStub()
        let expected = selection()
        overlay.onPresent = { callback in
            callback(.selected(self.window(id: 42)))
            callback(.selected(self.window(id: 99)))
            callback(.cancelled)
        }
        var resolvedIDs: [CGWindowID] = []
        let picker = makePicker(overlay: overlay) { metadata in
            resolvedIDs.append(metadata.windowID)
            return expected
        }

        let result = try await picker.selectWindow()

        XCTAssertEqual(result, expected)
        XCTAssertEqual(resolvedIDs, [42])
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testDisappearedTargetFailsSafelyAfterDismissingOverlay() async {
        let overlay = WindowPickerOverlayStub()
        overlay.onPresent = { $0(.selected(self.window(id: 42))) }
        var resolveCount = 0
        let picker = makePicker(overlay: overlay) { _ in
            resolveCount += 1
            return nil
        }
        do {
            _ = try await picker.selectWindow()
            XCTFail("A disappeared window must not produce a selection")
        } catch {
            XCTAssertEqual(error as? MeetingScreenshotCaptureError, .captureFailed)
        }
        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testPermissionFailureBeforePresentationIsNotHidden() async {
        let overlay = WindowPickerOverlayStub()
        let picker = MeetingScreenshotDirectWindowPicker(
            loadSnapshot: { throw MeetingScreenshotCaptureError.screenRecordingDenied },
            resolveSelection: { _ in self.selection() },
            makeOverlay: { overlay }
        )
        do {
            _ = try await picker.selectWindow()
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(error as? MeetingScreenshotCaptureError, .screenRecordingDenied)
        }
        XCTAssertEqual(overlay.presentCount, 0)
        XCTAssertEqual(overlay.dismissCount, 0)
    }

    func testFailedPresentationCleansUpPartialOverlay() async {
        let overlay = WindowPickerOverlayStub()
        overlay.presentationError = MeetingScreenshotCaptureError.noDisplayAvailable
        let picker = makePicker(overlay: overlay) { _ in self.selection() }
        do {
            _ = try await picker.selectWindow()
            XCTFail("Expected presentation failure")
        } catch {
            XCTAssertEqual(error as? MeetingScreenshotCaptureError, .noDisplayAvailable)
        }
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testTaskCancellationDismissesOverlayAndKeepsCancellationTyped() async {
        let overlay = WindowPickerOverlayStub()
        let presented = expectation(description: "Synthetic overlay presented")
        overlay.onPresent = { _ in presented.fulfill() }
        let picker = makePicker(overlay: overlay) { _ in self.selection() }
        let task = Task { try await picker.selectWindow() }
        await fulfillment(of: [presented], timeout: 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testCancellationBeforeQueuedResolutionStartsDoesNotCallResolver() async {
        let overlay = WindowPickerOverlayStub()
        let resolverCalled = expectation(description: "Cancelled resolver must never run")
        resolverCalled.isInverted = true
        var resolveCount = 0
        let picker = makePicker(overlay: overlay) { _ in
            resolveCount += 1
            resolverCalled.fulfill()
            return self.selection()
        }
        var caller: Task<MeetingScreenshotWindowSelection?, Error>?
        overlay.onPresent = { callback in
            callback(.selected(self.window(id: 42)))
            // The resolution task is queued on MainActor, but cannot start
            // while this synchronous synthetic callback is still executing.
            caller?.cancel()
        }
        let task = Task { try await picker.selectWindow() }
        caller = task
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [resolverCalled], timeout: 0.05)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testAlreadyCancelledCallerNeverLoadsMetadataOrCreatesOverlay() async {
        var loadCount = 0
        var makeCount = 0
        let picker = MeetingScreenshotDirectWindowPicker(
            loadSnapshot: {
                loadCount += 1
                return self.snapshot()
            },
            resolveSelection: { _ in self.selection() },
            makeOverlay: {
                makeCount += 1
                return WindowPickerOverlayStub()
            }
        )
        let task = Task { try await picker.selectWindow() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(makeCount, 0)
    }

    func testCancellationDuringNoncooperativeResolutionDiscardsLateSelection() async {
        let overlay = WindowPickerOverlayStub()
        overlay.onPresent = { $0(.selected(self.window(id: 42))) }
        let entered = expectation(description: "Synthetic resolver entered")
        let released = expectation(description: "Synthetic resolver returned")
        let pause = WindowPickerTestPause()
        let picker = makePicker(overlay: overlay) { _ in
            entered.fulfill()
            await pause.wait()
            released.fulfill()
            return self.selection()
        }
        let task = Task { try await picker.selectWindow() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation without waiting for the resolver")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        pause.release()
        if overlay.presentCount > 0 {
            await fulfillment(of: [released], timeout: 1)
        }
        XCTAssertEqual(overlay.dismissCount, 1)
    }

    func testCancelledLoaderCannotPresentOrCloseANewerRequest() async throws {
        let previousOverlay = WindowPickerOverlayStub()
        let currentOverlay = WindowPickerOverlayStub()
        let entered = expectation(description: "Old synthetic loader entered")
        let released = expectation(description: "Old synthetic loader returned")
        let currentPresented = expectation(description: "Current synthetic overlay presented")
        let pause = WindowPickerTestPause()
        var loadCount = 0
        var makeCount = 0
        let picker = MeetingScreenshotDirectWindowPicker(
            loadSnapshot: {
                loadCount += 1
                if loadCount == 1 {
                    entered.fulfill()
                    await pause.wait()
                    released.fulfill()
                }
                return self.snapshot()
            },
            resolveSelection: { _ in self.selection() },
            makeOverlay: {
                makeCount += 1
                return makeCount == 1 ? currentOverlay : previousOverlay
            }
        )
        let previous = Task { try await picker.selectWindow() }
        await fulfillment(of: [entered], timeout: 1)
        previous.cancel()
        do {
            _ = try await previous.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        currentOverlay.onPresent = { _ in currentPresented.fulfill() }
        let current = Task { try await picker.selectWindow() }
        await fulfillment(of: [currentPresented], timeout: 1)
        pause.release()
        if loadCount > 0 {
            await fulfillment(of: [released], timeout: 1)
        }
        XCTAssertEqual(currentOverlay.dismissCount, 0)
        XCTAssertEqual(previousOverlay.presentCount, 0)
        XCTAssertEqual(makeCount, 1)
        currentOverlay.send(.cancelled)
        let currentResult = try await current.value
        XCTAssertNil(currentResult)
        XCTAssertEqual(currentOverlay.dismissCount, 1)
    }

    func testOldOverlayCallbackCannotCompleteNewRequest() async throws {
        let previousOverlay = WindowPickerOverlayStub()
        let currentOverlay = WindowPickerOverlayStub()
        previousOverlay.onPresent = { $0(.cancelled) }
        var makeCount = 0
        let picker = MeetingScreenshotDirectWindowPicker(
            loadSnapshot: { self.snapshot() },
            resolveSelection: { _ in self.selection() },
            makeOverlay: {
                makeCount += 1
                return makeCount == 1 ? previousOverlay : currentOverlay
            }
        )
        let previousResult = try await picker.selectWindow()
        XCTAssertNil(previousResult)
        currentOverlay.onPresent = { callback in
            previousOverlay.send(.selected(self.window(id: 99)))
            callback(.cancelled)
        }

        let currentResult = try await picker.selectWindow()

        XCTAssertNil(currentResult)
        XCTAssertEqual(previousOverlay.dismissCount, 1)
        XCTAssertEqual(currentOverlay.dismissCount, 1)
    }

    private func makePicker(
        overlay: WindowPickerOverlayStub,
        resolve: @escaping MeetingScreenshotDirectWindowPicker.SelectionResolver
    ) -> MeetingScreenshotDirectWindowPicker {
        MeetingScreenshotDirectWindowPicker(
            loadSnapshot: { self.snapshot() },
            resolveSelection: resolve,
            makeOverlay: { overlay }
        )
    }

    private func snapshot() -> MeetingScreenshotWindowPickerSnapshot {
        MeetingScreenshotWindowPickerSnapshot(
            windowsFrontToBack: [window(id: 42)],
            displays: [mainDisplay], ownProcessID: ownProcessID
        )
    }

    private func hit(
        _ windows: [MeetingScreenshotWindowMetadata],
        at point: CGPoint = CGPoint(x: 100, y: 100)
    ) -> MeetingScreenshotWindowMetadata? {
        MeetingScreenshotWindowHitTest.frontmostWindow(
            at: point, windowsFrontToBack: windows,
            ownProcessID: ownProcessID, displayBounds: [mainDisplay.quartzFrame]
        )
    }

    private func window(
        id: CGWindowID,
        bounds: CGRect = CGRect(x: 20, y: 20, width: 400, height: 300)
    ) -> MeetingScreenshotWindowMetadata {
        MeetingScreenshotWindowMetadata(windowID: id, processID: 200, bounds: bounds)
    }

    private func selection() -> MeetingScreenshotWindowSelection {
        MeetingScreenshotWindowSelection(
            contentRect: CGRect(x: 20, y: 20, width: 400, height: 300),
            pointPixelScale: 2
        )
    }
}

@MainActor
private final class WindowPickerOverlayStub: MeetingScreenshotWindowSelectionPresenting {
    typealias EventHandler = @MainActor (MeetingScreenshotWindowOverlayEvent) -> Void
    var onPresent: ((@escaping EventHandler) -> Void)?
    var onDismiss: (() -> Void)?
    var presentationError: Error?
    private var handler: EventHandler?
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present(
        snapshot: MeetingScreenshotWindowPickerSnapshot,
        onEvent: @escaping EventHandler
    ) throws {
        presentCount += 1
        handler = onEvent
        if let presentationError { throw presentationError }
        onPresent?(onEvent)
    }

    func dismiss() {
        dismissCount += 1
        onDismiss?()
        // Retain the callback to simulate an already-enqueued late event.
    }

    func send(_ event: MeetingScreenshotWindowOverlayEvent) {
        handler?(event)
    }
}

@MainActor
private final class WindowPickerTestPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
