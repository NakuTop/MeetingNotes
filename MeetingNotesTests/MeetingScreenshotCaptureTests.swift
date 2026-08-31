import CoreGraphics
import ImageIO
import ScreenCaptureKit
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingScreenshotCaptureTests: XCTestCase {
    func testSelectorUsesDisplayContainingMouseLocation() {
        let main = display(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMain: true
        )
        let secondary = display(
            id: 2,
            frame: CGRect(x: 100, y: 0, width: 120, height: 100)
        )

        let selected = MeetingScreenshotDisplaySelector.select(
            from: [main, secondary],
            mouseLocation: CGPoint(x: 150, y: 40)
        )

        XCTAssertEqual(selected, secondary)
    }

    func testSelectorFallsBackToMainDisplayOutsideKnownFrames() {
        let secondary = display(
            id: 2,
            frame: CGRect(x: 100, y: 0, width: 120, height: 100)
        )
        let main = display(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMain: true
        )

        let selected = MeetingScreenshotDisplaySelector.select(
            from: [secondary, main],
            mouseLocation: CGPoint(x: -500, y: -500)
        )

        XCTAssertEqual(selected, main)
    }

    func testCaptureEncodesFullResolutionPNG() async throws {
        let image = try makeImage(width: 4, height: 3)
        let backend = MeetingScreenshotCaptureBackendStub(
            displayIDs: [42],
            image: image
        )
        let snapshot = MeetingScreenshotScreenSnapshot(
            mouseLocation: CGPoint(x: 20, y: 20),
            displays: [
                display(
                    id: 42,
                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    pixelWidth: 4,
                    pixelHeight: 3,
                    isMain: true
                )
            ]
        )
        let capture = MeetingScreenshotCaptureService(
            backend: backend,
            screenSnapshot: { snapshot }
        )

        let result = try await capture.captureDisplayUnderMouse()

        XCTAssertEqual(result.pixelWidth, 4)
        XCTAssertEqual(result.pixelHeight, 3)
        XCTAssertEqual(result.pngData.prefix(8), Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        ]))
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(result.pngData as CFData, nil)
        )
        let decoded = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 3)

        let requests = await backend.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.displayID, 42)
        XCTAssertEqual(request.pixelWidth, 4)
        XCTAssertEqual(request.pixelHeight, 3)
    }

    func testPermissionFailureReturnsNoImageData() async throws {
        let backend = MeetingScreenshotCaptureBackendStub(
            displayIDs: [7],
            image: try makeImage(width: 2, height: 2),
            shareableContentFailure: .permissionDenied
        )
        let snapshot = MeetingScreenshotScreenSnapshot(
            mouseLocation: .zero,
            displays: [display(id: 7, isMain: true)]
        )
        let capture = MeetingScreenshotCaptureService(
            backend: backend,
            screenSnapshot: { snapshot }
        )

        do {
            _ = try await capture.captureDisplayUnderMouse()
            XCTFail("Expected screen-recording denial")
        } catch {
            XCTAssertEqual(
                error as? MeetingScreenshotCaptureError,
                .screenRecordingDenied
            )
        }
        let requests = await backend.requests()
        XCTAssertEqual(requests.count, 0)
    }

    func testCancellationAfterShareableContentAwaitDiscardsImage() async throws {
        let gate = MeetingScreenshotCaptureTestGate()
        let backend = MeetingScreenshotCaptureBackendStub(
            displayIDs: [9],
            image: try makeImage(width: 2, height: 2),
            shareableContentGate: gate
        )
        let snapshot = MeetingScreenshotScreenSnapshot(
            mouseLocation: .zero,
            displays: [display(id: 9, isMain: true)]
        )
        let capture = MeetingScreenshotCaptureService(
            backend: backend,
            screenSnapshot: { snapshot }
        )
        let task = Task {
            try await capture.captureDisplayUnderMouse()
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await backend.requests()
        XCTAssertEqual(requests.count, 0)
    }

    private func display(
        id: CGDirectDisplayID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
        pixelWidth: Int = 100,
        pixelHeight: Int = 100,
        isMain: Bool = false
    ) -> MeetingScreenshotDisplayDescriptor {
        MeetingScreenshotDisplayDescriptor(
            displayID: id,
            frame: frame,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isMain: isMain
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let bytes = Data(
            repeating: 0x7F,
            count: width * height * 4
        )
        let provider = try XCTUnwrap(
            CGDataProvider(data: bytes as CFData)
        )
        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}

private enum MeetingScreenshotCaptureStubFailure: Sendable {
    case permissionDenied
}

private struct MeetingScreenshotCaptureRequest: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
}

private actor MeetingScreenshotCaptureBackendStub:
    MeetingScreenshotCaptureBackend {
    private let displayIDs: [CGDirectDisplayID]
    private let image: MeetingScreenshotCapturedImage
    private let shareableContentFailure: MeetingScreenshotCaptureStubFailure?
    private let shareableContentGate: MeetingScreenshotCaptureTestGate?
    private var recordedRequests: [MeetingScreenshotCaptureRequest] = []

    init(
        displayIDs: [CGDirectDisplayID],
        image: CGImage,
        shareableContentFailure: MeetingScreenshotCaptureStubFailure? = nil,
        shareableContentGate: MeetingScreenshotCaptureTestGate? = nil
    ) {
        self.displayIDs = displayIDs
        self.image = MeetingScreenshotCapturedImage(image)
        self.shareableContentFailure = shareableContentFailure
        self.shareableContentGate = shareableContentGate
    }

    func shareableDisplayIDs() async throws -> [CGDirectDisplayID] {
        if let shareableContentGate {
            await shareableContentGate.pause()
        }
        if shareableContentFailure == .permissionDenied {
            throw NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.userDeclined.rawValue
            )
        }
        return displayIDs
    }

    func captureImage(
        displayID: CGDirectDisplayID,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage {
        recordedRequests.append(
            MeetingScreenshotCaptureRequest(
                displayID: displayID,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
        return image
    }

    func requests() -> [MeetingScreenshotCaptureRequest] {
        recordedRequests
    }
}

private actor MeetingScreenshotCaptureTestGate {
    private var isEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
