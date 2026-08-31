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

protocol MeetingScreenshotCapturing: Sendable {
    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult
}

struct MeetingScreenshotDisplayDescriptor: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool
}

struct MeetingScreenshotScreenSnapshot: Equatable, Sendable {
    let mouseLocation: CGPoint
    let displays: [MeetingScreenshotDisplayDescriptor]
}

enum MeetingScreenshotDisplaySelector {
    static func select(
        from displays: [MeetingScreenshotDisplayDescriptor],
        mouseLocation: CGPoint
    ) -> MeetingScreenshotDisplayDescriptor? {
        displays.first { $0.frame.contains(mouseLocation) }
            ?? displays.first(where: \.isMain)
            ?? displays.first
    }
}

struct MeetingScreenshotCapturedImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

protocol MeetingScreenshotCaptureBackend: Sendable {
    func shareableDisplayIDs() async throws -> [CGDirectDisplayID]

    func captureImage(
        displayID: CGDirectDisplayID,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage
}

struct MeetingScreenshotCaptureService: MeetingScreenshotCapturing, Sendable {
    typealias ScreenSnapshotProvider =
        @MainActor @Sendable () -> MeetingScreenshotScreenSnapshot

    private let backend: any MeetingScreenshotCaptureBackend
    private let screenSnapshot: ScreenSnapshotProvider

    init(
        backend: any MeetingScreenshotCaptureBackend =
            ScreenCaptureKitMeetingScreenshotBackend(),
        screenSnapshot: @escaping ScreenSnapshotProvider = {
            MeetingScreenshotScreenSnapshotReader.current()
        }
    ) {
        self.backend = backend
        self.screenSnapshot = screenSnapshot
    }

    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        try Task.checkCancellation()
        let snapshot = await screenSnapshot()
        try Task.checkCancellation()
        guard let selected = MeetingScreenshotDisplaySelector.select(
            from: snapshot.displays,
            mouseLocation: snapshot.mouseLocation
        ) else {
            throw MeetingScreenshotCaptureError.noDisplayAvailable
        }

        let shareableDisplayIDs: [CGDirectDisplayID]
        do {
            shareableDisplayIDs = try await backend.shareableDisplayIDs()
        } catch {
            throw Self.captureError(from: error)
        }
        try Task.checkCancellation()
        guard shareableDisplayIDs.contains(selected.displayID) else {
            throw MeetingScreenshotCaptureError.selectedDisplayUnavailable
        }

        let captured: MeetingScreenshotCapturedImage
        do {
            captured = try await backend.captureImage(
                displayID: selected.displayID,
                pixelWidth: selected.pixelWidth,
                pixelHeight: selected.pixelHeight
            )
        } catch {
            throw Self.captureError(from: error)
        }
        try Task.checkCancellation()

        let image = captured.image
        guard let pngData = MeetingScreenshotPNGEncoder.encode(image) else {
            throw MeetingScreenshotCaptureError.pngEncodingFailed
        }
        return MeetingScreenshotCaptureResult(
            pngData: pngData,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
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
private enum MeetingScreenshotScreenSnapshotReader {
    static func current() -> MeetingScreenshotScreenSnapshot {
        let mainDisplayID = NSScreen.main.flatMap(displayID(for:))
        let displays: [MeetingScreenshotDisplayDescriptor] =
            NSScreen.screens.compactMap { screen
                -> MeetingScreenshotDisplayDescriptor? in
            guard let displayID = displayID(for: screen) else { return nil }
            let pixelWidth = Int(CGDisplayPixelsWide(displayID))
            let pixelHeight = Int(CGDisplayPixelsHigh(displayID))
            return MeetingScreenshotDisplayDescriptor(
                displayID: displayID,
                frame: screen.frame,
                pixelWidth: max(
                    1,
                    pixelWidth > 0
                        ? pixelWidth
                        : Int(screen.frame.width * screen.backingScaleFactor)
                ),
                pixelHeight: max(
                    1,
                    pixelHeight > 0
                        ? pixelHeight
                        : Int(screen.frame.height * screen.backingScaleFactor)
                ),
                isMain: displayID == mainDisplayID
            )
        }
        return MeetingScreenshotScreenSnapshot(
            mouseLocation: NSEvent.mouseLocation,
            displays: displays
        )
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

private actor ScreenCaptureKitMeetingScreenshotBackend:
    MeetingScreenshotCaptureBackend {
    private var displaysByID: [CGDirectDisplayID: SCDisplay] = [:]

    func shareableDisplayIDs() async throws -> [CGDirectDisplayID] {
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        displaysByID = Dictionary(
            uniqueKeysWithValues: content.displays.map {
                ($0.displayID, $0)
            }
        )
        return content.displays.map(\.displayID)
    }

    func captureImage(
        displayID: CGDirectDisplayID,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> MeetingScreenshotCapturedImage {
        guard let display = displaysByID[displayID] else {
            throw MeetingScreenshotCaptureError.selectedDisplayUnavailable
        }
        try Task.checkCancellation()

        let filter = SCContentFilter(
            display: display,
            excludingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, pixelWidth)
        configuration.height = max(1, pixelHeight)
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
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

private enum MeetingScreenshotPNGEncoder {
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
