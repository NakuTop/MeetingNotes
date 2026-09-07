import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingScreenshotCaptureTests: XCTestCase {
    func testRealImageCompletionAcceptsBackgroundQueue() async throws {
        let image = MeetingScreenshotCapturedImage(try makeImage(width: 2, height: 2))
        let backend = ScreenCaptureKitMeetingScreenshotBackend { _, _, completion in
            let invocation = ScreenshotImageBackgroundCompletion(completion: completion)
            DispatchQueue.global().async {
                invocation.completion(image.image, nil)
            }
        }
        let result = try await backend.captureImage(
            selection: MeetingScreenshotWindowSelection(
                contentRect: CGRect(x: 0, y: 0, width: 2, height: 2),
                pointPixelScale: 1, contentFilter: SCContentFilter()
            ),
            pixelWidth: 2, pixelHeight: 2
        )
        XCTAssertEqual(result.image.width, 2)
    }

    func testRealPickerCancellationCallbackAcceptsBackgroundQueue() async throws {
        let gate = MeetingScreenshotSelectionGate()
        let invocation = ScreenshotPickerBackgroundInvocation(
            observer: MeetingScreenshotPickerObserver(gate: gate),
            picker: SCContentSharingPicker.shared
        )
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            invocation.observer.contentSharingPicker(
                invocation.picker, didCancelFor: nil
            )
        }.value
        let result = try await gate.wait()
        XCTAssertNil(result)
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testRealPickerFailureCallbackAcceptsBackgroundQueue() async {
        let gate = MeetingScreenshotSelectionGate()
        let observer = MeetingScreenshotPickerObserver(gate: gate)
        await Task.detached {
            observer.contentSharingPickerStartDidFailWithError(
                MeetingScreenshotCaptureError.captureFailed
            )
        }.value
        do {
            _ = try await gate.wait()
            XCTFail("Expected callback failure")
        } catch {
            XCTAssertEqual(error as? MeetingScreenshotCaptureError, .captureFailed)
        }
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testRealPickerUpdateCallbackAcceptsBackgroundQueueWithoutPresentingUI() async {
        let gate = MeetingScreenshotSelectionGate()
        let invocation = ScreenshotPickerBackgroundInvocation(
            observer: MeetingScreenshotPickerObserver(gate: gate),
            picker: SCContentSharingPicker.shared
        )
        await Task.detached {
            // An empty filter deliberately exercises the invalid-selection
            // branch of the real Objective-C callback, without capturing data.
            invocation.observer.contentSharingPicker(
                invocation.picker, didUpdateWith: SCContentFilter(), for: nil
            )
        }.value
        do {
            _ = try await gate.wait()
            XCTFail("Expected an invalid-window error")
        } catch {
            XCTAssertEqual(error as? MeetingScreenshotCaptureError, .captureFailed)
        }
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testLatePickerCallbackCannotFinishAnotherSelection() async throws {
        let previous = MeetingScreenshotSelectionGate()
        let current = MeetingScreenshotSelectionGate()
        let observer = MeetingScreenshotPickerObserver(gate: previous)
        previous.finish(.cancelled)
        _ = try await previous.wait()
        await Task.detached {
            observer.contentSharingPickerStartDidFailWithError(
                MeetingScreenshotCaptureError.captureFailed
            )
        }.value
        let selection = MeetingScreenshotWindowSelection(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            pointPixelScale: 2
        )
        current.finish(.selected(selection))
        let result = try await current.wait()
        XCTAssertEqual(result, selection)
        XCTAssertEqual(previous.resumeCount, 1)
        XCTAssertEqual(current.resumeCount, 1)
    }

    func testPNGEncodingRunsOffMainThread() async throws {
        let encodingThread = MeetingScreenshotEncodingThreadRecorder()
        let capture = try makeEncodingTestCapture { captured in
            encodingThread.record(Thread.isMainThread)
            return MeetingScreenshotPNGEncoder.encode(captured.image)
        }

        let captured = try await capture.captureSelectedWindow()

        XCTAssertNotNil(captured)
        XCTAssertEqual(encodingThread.wasMainThread, false)
    }

    func testCancellationDuringPNGEncodingDiscardsLateImage() async throws {
        let capture = try makeEncodingTestCapture { captured in
            let data = MeetingScreenshotPNGEncoder.encode(captured.image)
            withUnsafeCurrentTask { $0?.cancel() }
            return data
        }
        let task = Task { try await capture.captureSelectedWindow() }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to discard the encoded image")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPNGEncodingPreservesDimensionsFormatAndPixels() async throws {
        let capture = try makeEncodingTestCapture()
        let captured = try await capture.captureSelectedWindow()
        let result = try XCTUnwrap(captured)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(
            result.pngData as CFData, nil
        ))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            source, 0, nil
        ))

        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(result.pixelWidth, 31)
        XCTAssertEqual(result.pixelHeight, 17)
        XCTAssertEqual(decoded.width, result.pixelWidth)
        XCTAssertEqual(decoded.height, result.pixelHeight)
        XCTAssertEqual(
            try rgbaPixels(decoded),
            try rgbaPixels(makeEncodingTestImage())
        )
    }

    func testWindowSelectionCapturesAtNativeRetinaResolution() async throws {
        let selection = MeetingScreenshotWindowSelection(
            id: fixedUUID("00000000-0000-0000-0000-000000000042"),
            contentRect: CGRect(x: 20, y: 40, width: 640, height: 360),
            pointPixelScale: 2
        )
        let backend = MeetingScreenshotCaptureBackendStub(
            selection: selection,
            image: try makeImage(width: 1_280, height: 720)
        )
        let capture = MeetingScreenshotCaptureService(
            backend: backend,
            maximumPixelSize: {
                MeetingScreenshotPixelSize(width: 3_456, height: 2_234)
            }
        )

        let captured = try await capture.captureSelectedWindow()
        let result = try XCTUnwrap(captured)

        XCTAssertEqual(result.pixelWidth, 1_280)
        XCTAssertEqual(result.pixelHeight, 720)
        XCTAssertEqual(result.pngData.prefix(8), Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]))
        let request = try XCTUnwrap(backend.requests.first)
        XCTAssertEqual(request.selectionID, selection.id)
        XCTAssertEqual(request.pixelWidth, 1_280)
        XCTAssertEqual(request.pixelHeight, 720)
        XCTAssertEqual(backend.selectionRequestCount, 1)
    }

    func testOversizedWindowIsDownscaledWithoutChangingAspectRatio()
        async throws {
        let selection = MeetingScreenshotWindowSelection(
            contentRect: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
            pointPixelScale: 2
        )
        let backend = MeetingScreenshotCaptureBackendStub(
            selection: selection,
            image: try makeImage(width: 3_000, height: 1_500)
        )
        let capture = MeetingScreenshotCaptureService(
            backend: backend,
            maximumPixelSize: {
                MeetingScreenshotPixelSize(width: 3_000, height: 2_000)
            }
        )

        _ = try await capture.captureSelectedWindow()

        let request = try XCTUnwrap(backend.requests.first)
        XCTAssertEqual(request.pixelWidth, 3_000)
        XCTAssertEqual(request.pixelHeight, 1_500)
    }

    func testPickerCancellationReturnsNilWithoutCapturing() async throws {
        let backend = MeetingScreenshotCaptureBackendStub(
            selection: nil,
            image: try makeImage(width: 2, height: 2)
        )
        let capture = MeetingScreenshotCaptureService(backend: backend)

        let result = try await capture.captureSelectedWindow()

        XCTAssertNil(result)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(backend.selectionRequestCount, 1)
    }

    func testPermissionFailureReturnsNoImageData() async throws {
        let backend = MeetingScreenshotCaptureBackendStub(
            selection: MeetingScreenshotWindowSelection(
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                pointPixelScale: 2
            ),
            image: try makeImage(width: 2, height: 2),
            selectionFailure: .permissionDenied
        )
        let capture = MeetingScreenshotCaptureService(backend: backend)

        do {
            _ = try await capture.captureSelectedWindow()
            XCTFail("Expected screen-recording denial")
        } catch {
            XCTAssertEqual(
                error as? MeetingScreenshotCaptureError,
                .screenRecordingDenied
            )
        }
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testCancellationAfterPickerAwaitDiscardsSelection() async throws {
        let gate = MeetingScreenshotCaptureTestGate()
        let backend = MeetingScreenshotCaptureBackendStub(
            selection: MeetingScreenshotWindowSelection(
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                pointPixelScale: 2
            ),
            image: try makeImage(width: 200, height: 200),
            selectionGate: gate
        )
        let capture = MeetingScreenshotCaptureService(backend: backend)
        let task = Task {
            try await capture.captureSelectedWindow()
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
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testTerminalPickerResultBeforeWaitRegistrationIsRetained()
        async throws {
        let gate = MeetingScreenshotSelectionGate()
        gate.finish(.cancelled)

        let result = try await gate.wait()

        XCTAssertNil(result)
        XCTAssertEqual(gate.resumeCount, 1)
    }

    func testOnlyFirstPickerTerminalResultWins() async throws {
        let gate = MeetingScreenshotSelectionGate()
        let selection = MeetingScreenshotWindowSelection(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            pointPixelScale: 2
        )
        gate.finish(.selected(selection))
        gate.finish(.cancelled)
        gate.finish(.failure(MeetingScreenshotCaptureError.captureFailed))

        let waited = try await gate.wait()
        let result = try XCTUnwrap(waited)

        XCTAssertEqual(result.id, selection.id)
        XCTAssertEqual(gate.resumeCount, 1)
    }

    private func fixedUUID(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func makeEncodingTestCapture(
        encodePNG: @escaping MeetingScreenshotCaptureService.PNGEncoder = {
            MeetingScreenshotPNGEncoder.encode($0.image)
        }
    ) throws -> MeetingScreenshotCaptureService {
        MeetingScreenshotCaptureService(
            backend: MeetingScreenshotCaptureBackendStub(
                selection: MeetingScreenshotWindowSelection(
                    contentRect: CGRect(x: 0, y: 0, width: 31, height: 17),
                    pointPixelScale: 1
                ),
                image: try makeEncodingTestImage()
            ),
            maximumPixelSize: {
                MeetingScreenshotPixelSize(width: 1_000, height: 1_000)
            },
            encodePNG: encodePNG
        )
    }

    private func makeEncodingTestImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 31,
            height: 17,
            bitsPerComponent: 8,
            bytesPerRow: 31 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 31, height: 17))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 7, height: 11))
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaPixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(
            x: 0, y: 0, width: image.width, height: image.height
        ))
        return Data(
            bytes: try XCTUnwrap(context.data),
            count: image.width * image.height * 4
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let bytes = Data(repeating: 0x7F, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
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

private struct ScreenshotPickerBackgroundInvocation: @unchecked Sendable {
    let observer: any SCContentSharingPickerObserver
    let picker: SCContentSharingPicker
}

private struct ScreenshotImageBackgroundCompletion: @unchecked Sendable {
    let completion: (CGImage?, Error?) -> Void
}

private final class MeetingScreenshotEncodingThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasMainThread: Bool?

    var wasMainThread: Bool? {
        lock.withLock { storedWasMainThread }
    }

    func record(_ wasMainThread: Bool) {
        lock.withLock { storedWasMainThread = wasMainThread }
    }
}

private enum MeetingScreenshotCaptureStubFailure: Sendable {
    case permissionDenied
}

private struct MeetingScreenshotCaptureRequest: Equatable, Sendable {
    let selectionID: UUID
    let pixelWidth: Int
    let pixelHeight: Int
}

@MainActor
private final class MeetingScreenshotCaptureBackendStub:
    MeetingScreenshotCaptureBackend {
    private let selection: MeetingScreenshotWindowSelection?
    private let image: MeetingScreenshotCapturedImage
    private let selectionFailure: MeetingScreenshotCaptureStubFailure?
    private let selectionGate: MeetingScreenshotCaptureTestGate?

    private(set) var selectionRequestCount = 0
    private(set) var requests: [MeetingScreenshotCaptureRequest] = []

    init(
        selection: MeetingScreenshotWindowSelection?,
        image: CGImage,
        selectionFailure: MeetingScreenshotCaptureStubFailure? = nil,
        selectionGate: MeetingScreenshotCaptureTestGate? = nil
    ) {
        self.selection = selection
        self.image = MeetingScreenshotCapturedImage(image)
        self.selectionFailure = selectionFailure
        self.selectionGate = selectionGate
    }

    func selectWindow() async throws -> MeetingScreenshotWindowSelection? {
        selectionRequestCount += 1
        if let selectionGate {
            await selectionGate.pause()
        }
        if selectionFailure == .permissionDenied {
            throw NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.userDeclined.rawValue
            )
        }
        return selection
    }

    func captureImage(
        selection: MeetingScreenshotWindowSelection,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage {
        requests.append(
            MeetingScreenshotCaptureRequest(
                selectionID: selection.id,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
        return image
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
