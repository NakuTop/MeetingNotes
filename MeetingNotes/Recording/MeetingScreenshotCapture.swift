import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum MeetingScreenshotCaptureError: Error, Equatable, Sendable {
    case screenRecordingDenied
    case noDisplayAvailable
    case selectedDisplayUnavailable
    case captureFailed
    case pngEncodingFailed
}

struct MeetingScreenshotCaptureResult: Equatable, Sendable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

@MainActor
protocol MeetingScreenshotCapturing {
    func captureSelectedWindow() async throws
        -> MeetingScreenshotCaptureResult?
}

struct MeetingScreenshotPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum MeetingScreenshotWindowPixelPolicy {
    static func outputSize(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        maximum: MeetingScreenshotPixelSize
    ) -> MeetingScreenshotPixelSize? {
        guard contentRect.width.isFinite,
              contentRect.height.isFinite,
              pointPixelScale.isFinite,
              contentRect.width > 0,
              contentRect.height > 0,
              pointPixelScale > 0,
              maximum.width > 0,
              maximum.height > 0 else {
            return nil
        }

        let nativeWidth = ceil(contentRect.width * pointPixelScale)
        let nativeHeight = ceil(contentRect.height * pointPixelScale)
        guard nativeWidth.isFinite,
              nativeHeight.isFinite,
              nativeWidth > 0,
              nativeHeight > 0,
              nativeWidth <= CGFloat(Int.max),
              nativeHeight <= CGFloat(Int.max) else {
            return nil
        }

        let scale = min(
            1,
            CGFloat(maximum.width) / nativeWidth,
            CGFloat(maximum.height) / nativeHeight
        )
        return MeetingScreenshotPixelSize(
            width: max(1, Int(floor(nativeWidth * scale))),
            height: max(1, Int(floor(nativeHeight * scale)))
        )
    }
}

struct MeetingScreenshotWindowSelection: Equatable, @unchecked Sendable {
    let id: UUID
    let contentRect: CGRect
    let pointPixelScale: CGFloat

    fileprivate let contentFilter: SCContentFilter?

    init(
        id: UUID = UUID(),
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        contentFilter: SCContentFilter? = nil
    ) {
        self.id = id
        self.contentRect = contentRect
        self.pointPixelScale = pointPixelScale
        self.contentFilter = contentFilter
    }

    static func == (
        lhs: MeetingScreenshotWindowSelection,
        rhs: MeetingScreenshotWindowSelection
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.contentRect == rhs.contentRect
            && lhs.pointPixelScale == rhs.pointPixelScale
    }
}

struct MeetingScreenshotCapturedImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

@MainActor
protocol MeetingScreenshotCaptureBackend {
    func selectWindow() async throws -> MeetingScreenshotWindowSelection?

    func captureImage(
        selection: MeetingScreenshotWindowSelection,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage
}

@MainActor
struct MeetingScreenshotCaptureService: MeetingScreenshotCapturing {
    typealias MaximumPixelSizeProvider =
        @MainActor @Sendable () -> MeetingScreenshotPixelSize?
    typealias PNGEncoder =
        @Sendable (MeetingScreenshotCapturedImage) -> Data?

    private let backend: any MeetingScreenshotCaptureBackend
    private let maximumPixelSize: MaximumPixelSizeProvider
    private let encodePNG: PNGEncoder

    init(
        backend: any MeetingScreenshotCaptureBackend =
            ScreenCaptureKitMeetingScreenshotBackend(),
        maximumPixelSize: @escaping MaximumPixelSizeProvider = {
            MeetingScreenshotMaximumPixelSizeReader.current()
        },
        encodePNG: @escaping PNGEncoder = {
            MeetingScreenshotPNGEncoder.encode($0.image)
        }
    ) {
        self.backend = backend
        self.maximumPixelSize = maximumPixelSize
        self.encodePNG = encodePNG
    }

    func captureSelectedWindow() async throws
        -> MeetingScreenshotCaptureResult? {
        try Task.checkCancellation()

        let selection: MeetingScreenshotWindowSelection?
        do {
            selection = try await backend.selectWindow()
        } catch {
            throw Self.captureError(from: error)
        }
        try Task.checkCancellation()
        guard let selection else { return nil }
        guard let maximum = maximumPixelSize() else {
            throw MeetingScreenshotCaptureError.noDisplayAvailable
        }
        guard let size = MeetingScreenshotWindowPixelPolicy.outputSize(
            contentRect: selection.contentRect,
            pointPixelScale: selection.pointPixelScale,
            maximum: maximum
        ) else {
            throw MeetingScreenshotCaptureError.captureFailed
        }

        let captured: MeetingScreenshotCapturedImage
        do {
            captured = try await backend.captureImage(
                selection: selection,
                pixelWidth: size.width,
                pixelHeight: size.height
            )
        } catch {
            throw Self.captureError(from: error)
        }
        try Task.checkCancellation()

        let image = captured.image
        guard let pngData = try await Self.encodeOffMainActor(
            captured,
            using: encodePNG
        ) else {
            throw MeetingScreenshotCaptureError.pngEncodingFailed
        }
        try Task.checkCancellation()
        return MeetingScreenshotCaptureResult(
            pngData: pngData,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private nonisolated static func encodeOffMainActor(
        _ image: MeetingScreenshotCapturedImage,
        using encoder: PNGEncoder
    ) async throws -> Data? {
        try Task.checkCancellation()
        let data = encoder(image)
        try Task.checkCancellation()
        return data
    }

    private static func captureError(from error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if let error = error as? MeetingScreenshotCaptureError {
            return error
        }
        if ScreenCaptureProbeResult(error: error) == .denied {
            return MeetingScreenshotCaptureError.screenRecordingDenied
        }
        return MeetingScreenshotCaptureError.captureFailed
    }
}

@MainActor
private enum MeetingScreenshotMaximumPixelSizeReader {
    static func current() -> MeetingScreenshotPixelSize? {
        let sizes = NSScreen.screens.compactMap { screen
            -> MeetingScreenshotPixelSize? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let pixelWidth = Int(CGDisplayPixelsWide(displayID))
            let pixelHeight = Int(CGDisplayPixelsHigh(displayID))
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }
            return MeetingScreenshotPixelSize(
                width: pixelWidth,
                height: pixelHeight
            )
        }
        guard let maximumWidth = sizes.map(\.width).max(),
              let maximumHeight = sizes.map(\.height).max() else {
            return nil
        }
        return MeetingScreenshotPixelSize(
            width: maximumWidth,
            height: maximumHeight
        )
    }
}

final class MeetingScreenshotSelectionGate: @unchecked Sendable {
    enum TerminalResult {
        case selected(MeetingScreenshotWindowSelection)
        case cancelled
        case failure(Error)
    }

    private enum State {
        case pending
        case terminal(TerminalResult)
        case waiting(
            CheckedContinuation<MeetingScreenshotWindowSelection?, Error>
        )
        case resumed
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var storedResumeCount = 0

    var resumeCount: Int {
        lock.withLock { storedResumeCount }
    }

    var isPending: Bool {
        lock.withLock {
            switch state {
            case .pending, .waiting: return true
            case .terminal, .resumed: return false
            }
        }
    }

    func wait() async throws -> MeetingScreenshotWindowSelection? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func finish(_ result: TerminalResult) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<
                MeetingScreenshotWindowSelection?, Error
            >? in
            switch state {
            case .pending:
                state = .terminal(result)
                return nil
            case let .waiting(continuation):
                state = .resumed
                storedResumeCount += 1
                return continuation
            case .terminal, .resumed:
                return nil
            }
        }
        if let continuation {
            Self.resume(continuation, with: result)
        }
    }

    private func register(
        _ continuation: CheckedContinuation<
            MeetingScreenshotWindowSelection?, Error
        >
    ) {
        let terminal = lock.withLock { () -> TerminalResult? in
            switch state {
            case .pending:
                state = .waiting(continuation)
                return nil
            case let .terminal(result):
                state = .resumed
                storedResumeCount += 1
                return result
            case .waiting, .resumed:
                state = .resumed
                storedResumeCount += 1
                return .failure(CancellationError())
            }
        }
        if let terminal {
            Self.resume(continuation, with: terminal)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<
            MeetingScreenshotWindowSelection?, Error
        >,
        with result: TerminalResult
    ) {
        switch result {
        case let .selected(selection):
            continuation.resume(returning: selection)
        case .cancelled:
            continuation.resume(returning: nil)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class ScreenCaptureKitMeetingScreenshotBackend:
    NSObject,
    MeetingScreenshotCaptureBackend {
    typealias CaptureImageOperation = @MainActor (
        SCContentFilter, SCStreamConfiguration,
        @escaping (CGImage?, Error?) -> Void
    ) -> Void

    private let captureImageOperation: CaptureImageOperation
    private let windowPicker: any MeetingScreenshotWindowSelecting

    init(
        windowPicker: any MeetingScreenshotWindowSelecting = MeetingScreenshotDirectWindowPicker(),
        captureImageOperation: @escaping CaptureImageOperation = { filter, configuration, completion in
        SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration,
            completionHandler: completion
        )
    }) {
        self.windowPicker = windowPicker
        self.captureImageOperation = captureImageOperation
        super.init()
    }

    func selectWindow() async throws -> MeetingScreenshotWindowSelection? {
        try await windowPicker.selectWindow()
    }

    func captureImage(
        selection: MeetingScreenshotWindowSelection,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage {
        guard let filter = selection.contentFilter else {
            throw MeetingScreenshotCaptureError.selectedDisplayUnavailable
        }
        try Task.checkCancellation()

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, pixelWidth)
        configuration.height = max(1, pixelHeight)
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            captureImageOperation(filter, configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: MeetingScreenshotCaptureError.captureFailed
                    )
                }
            }
        }
        try Task.checkCancellation()
        return MeetingScreenshotCapturedImage(image)
    }
}

// ScreenCaptureKit delivers these Objective-C callbacks on replayd's XPC queue,
// not MainActor. A per-request observer owns only an immutable, lock-protected
// gate; delayed callbacks cannot complete a later selection request.
final class MeetingScreenshotPickerObserver:
    NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let gate: MeetingScreenshotSelectionGate

    init(gate: MeetingScreenshotSelectionGate) {
        self.gate = gate
        super.init()
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        _ = picker
        _ = stream
        gate.finish(.cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        gate.finish(.failure(error))
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        _ = picker
        _ = stream
        guard filter.style == .window else {
            gate.finish(
                .failure(MeetingScreenshotCaptureError.captureFailed)
            )
            return
        }
        gate.finish(
            .selected(
                MeetingScreenshotWindowSelection(
                    contentRect: filter.contentRect,
                    pointPixelScale: CGFloat(filter.pointPixelScale),
                    contentFilter: filter
                )
            )
        )
    }
}

enum MeetingScreenshotPNGEncoder {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
