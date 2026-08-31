import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NotionScreenshotDerivativeError: Error, Equatable, Sendable {
    case invalidSourceImage
    case encodingFailed
    case unableToMeetByteLimit
}

protocol NotionScreenshotJPEGEncoding: Sendable {
    func encode(_ image: CGImage, quality: CGFloat) throws -> Data
}

struct ImageIONotionScreenshotJPEGEncoder: NotionScreenshotJPEGEncoding {
    func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NotionScreenshotDerivativeError.encodingFailed
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw NotionScreenshotDerivativeError.encodingFailed
        }
        return data as Data
    }
}

struct NotionScreenshotDerivative: Sendable {
    let fileURL: URL
    let fileName: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    private let owner: NotionScreenshotDerivativeOwner

    fileprivate init(
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        owner: NotionScreenshotDerivativeOwner
    ) {
        self.fileURL = fileURL
        fileName = fileURL.lastPathComponent
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.owner = owner
    }

    func cleanup() {
        owner.cleanup()
    }
}

private final class NotionScreenshotDerivativeOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var ownedDirectory: URL?

    init(ownedDirectory: URL) {
        self.ownedDirectory = ownedDirectory
    }

    func cleanup() {
        let directory = lock.withLock { () -> URL? in
            defer { ownedDirectory = nil }
            return ownedDirectory
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

actor NotionScreenshotDerivativeBuilder {
    typealias AttemptHook = @Sendable (Int) async throws -> Void

    static let maximumByteCount = 4_500_000

    private static let qualitySteps: [CGFloat] = [
        0.92, 0.82, 0.72, 0.62, 0.52, 0.42
    ]
    private static let scaleFactor: CGFloat = 0.85
    private static let maximumScaleAttempts = 18

    private let temporaryRoot: URL
    private let encoder: any NotionScreenshotJPEGEncoding
    private let attemptHook: AttemptHook
    private let fileManager: FileManager

    init(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        encoder: any NotionScreenshotJPEGEncoding =
            ImageIONotionScreenshotJPEGEncoder(),
        attemptHook: @escaping AttemptHook = { _ in }
    ) {
        self.temporaryRoot = temporaryRoot
        self.encoder = encoder
        self.attemptHook = attemptHook
        fileManager = .default
    }

    func build(from sourceURL: URL) async throws -> NotionScreenshotDerivative {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sourceImage.width > 0,
              sourceImage.height > 0 else {
            throw NotionScreenshotDerivativeError.invalidSourceImage
        }

        let ownedDirectory = temporaryRoot.appendingPathComponent(
            "MeetingNotes-NotionScreenshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: ownedDirectory,
            withIntermediateDirectories: true
        )

        do {
            var image = sourceImage
            var attempt = 0

            for scaleAttempt in 0..<Self.maximumScaleAttempts {
                for quality in Self.qualitySteps {
                    try await attemptHook(attempt)
                    attempt += 1
                    try Task.checkCancellation()

                    let data: Data
                    do {
                        data = try encoder.encode(image, quality: quality)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw NotionScreenshotDerivativeError.encodingFailed
                    }

                    guard data.count <= Self.maximumByteCount else {
                        continue
                    }

                    let outputURL = ownedDirectory.appendingPathComponent(
                        "screenshot.jpg",
                        isDirectory: false
                    )
                    try Task.checkCancellation()
                    try data.write(to: outputURL, options: .withoutOverwriting)
                    return NotionScreenshotDerivative(
                        fileURL: outputURL,
                        pixelWidth: image.width,
                        pixelHeight: image.height,
                        byteCount: data.count,
                        owner: NotionScreenshotDerivativeOwner(
                            ownedDirectory: ownedDirectory
                        )
                    )
                }

                guard scaleAttempt + 1 < Self.maximumScaleAttempts else {
                    break
                }
                image = try downscaled(image)
            }

            throw NotionScreenshotDerivativeError.unableToMeetByteLimit
        } catch {
            try? fileManager.removeItem(at: ownedDirectory)
            throw error
        }
    }

    private func downscaled(_ image: CGImage) throws -> CGImage {
        let width = max(1, Int((CGFloat(image.width) * Self.scaleFactor).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * Self.scaleFactor).rounded(.down)))
        guard width < image.width || height < image.height,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NotionScreenshotDerivativeError.unableToMeetByteLimit
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let result = context.makeImage() else {
            throw NotionScreenshotDerivativeError.encodingFailed
        }
        return result
    }
}
