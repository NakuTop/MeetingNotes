import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MeetingNotes

final class NotionScreenshotDerivativeBuilderTests: XCTestCase {
    func testSmallImageKeepsDimensionsAndStaysBelowLimit() async throws {
        let root = try makeTemporaryRoot()
        let sourceURL = root.appendingPathComponent("source.png")
        let sourceData = try makePNG(width: 640, height: 360)
        try sourceData.write(to: sourceURL)
        let builder = NotionScreenshotDerivativeBuilder(
            temporaryRoot: root
        )

        let derivative = try await builder.build(from: sourceURL)
        defer { derivative.cleanup() }

        XCTAssertEqual(derivative.pixelWidth, 640)
        XCTAssertEqual(derivative.pixelHeight, 360)
        XCTAssertLessThanOrEqual(
            derivative.byteCount,
            NotionScreenshotDerivativeBuilder.maximumByteCount
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(
            try imageType(at: derivative.fileURL),
            UTType.jpeg.identifier
        )
    }

    func testLargeImageShrinksUntilBelowFourPointFiveMiB() async throws {
        let root = try makeTemporaryRoot()
        let sourceURL = root.appendingPathComponent("large.png")
        let sourceData = try makePNG(width: 1_600, height: 1_000)
        try sourceData.write(to: sourceURL)
        let builder = NotionScreenshotDerivativeBuilder(
            temporaryRoot: root,
            encoder: DimensionSizedJPEGEncoder()
        )

        let derivative = try await builder.build(from: sourceURL)
        defer { derivative.cleanup() }

        XCTAssertLessThan(derivative.pixelWidth, 1_600)
        XCTAssertLessThan(derivative.pixelHeight, 1_000)
        XCTAssertLessThanOrEqual(derivative.byteCount, 4_500_000)
        XCTAssertEqual(derivative.byteCount, try Data(
            contentsOf: derivative.fileURL
        ).count)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testDerivativeUsesUniqueTemporaryPathAndCleanupIsOwnedIdempotent()
        async throws {
        let root = try makeTemporaryRoot()
        let sourceURL = root.appendingPathComponent("source.png")
        try makePNG(width: 320, height: 180).write(to: sourceURL)
        let keepURL = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keepURL)
        let builder = NotionScreenshotDerivativeBuilder(
            temporaryRoot: root
        )

        let first = try await builder.build(from: sourceURL)
        let second = try await builder.build(from: sourceURL)

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertNotEqual(
            first.fileURL.deletingLastPathComponent(),
            second.fileURL.deletingLastPathComponent()
        )
        first.cleanup()
        first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepURL.path))
        second.cleanup()
    }

    func testCancellationAndEncodingFailureRemoveTemporaryFiles()
        async throws {
        let root = try makeTemporaryRoot()
        let sourceURL = root.appendingPathComponent("source.png")
        try makePNG(width: 640, height: 360).write(to: sourceURL)
        let gate = DerivativeAttemptGate()
        let cancellingBuilder = NotionScreenshotDerivativeBuilder(
            temporaryRoot: root,
            attemptHook: { _ in
                await gate.pauseAttempt()
            }
        )
        let buildTask = Task {
            try await cancellingBuilder.build(from: sourceURL)
        }
        await gate.waitUntilPaused()

        buildTask.cancel()
        await gate.releaseAttempt()

        do {
            _ = try await buildTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(
            try derivativeDirectories(in: root),
            []
        )

        let failingBuilder = NotionScreenshotDerivativeBuilder(
            temporaryRoot: root,
            encoder: FailingJPEGEncoder()
        )
        do {
            _ = try await failingBuilder.build(from: sourceURL)
            XCTFail("Expected encoding failure")
        } catch {
            XCTAssertEqual(
                error as? NotionScreenshotDerivativeError,
                .encodingFailed
            )
        }
        XCTAssertEqual(try derivativeDirectories(in: root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotionScreenshotDerivativeBuilderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func derivativeDirectories(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            $0.lastPathComponent.hasPrefix("MeetingNotes-NotionScreenshot-")
        }.map(\.lastPathComponent)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.creationFailed
        }
        context.setFillColor(
            CGColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestImageError.creationFailed
        }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw TestImageError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.creationFailed
        }
        return data as Data
    }

    private func imageType(at url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TestImageError.creationFailed
        }
        return CGImageSourceGetType(source) as String?
    }
}

private enum TestImageError: Error {
    case creationFailed
}

private struct DimensionSizedJPEGEncoder: NotionScreenshotJPEGEncoding {
    func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        _ = quality
        return Data(count: image.width * image.height * 4)
    }
}

private struct FailingJPEGEncoder: NotionScreenshotJPEGEncoding {
    func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        _ = image
        _ = quality
        throw TestImageError.creationFailed
    }
}

private actor DerivativeAttemptGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseAttempt() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func releaseAttempt() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
