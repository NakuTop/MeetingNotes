import XCTest
@testable import MeetingNotes

final class MeetingFileStoreTests: XCTestCase {
    func testEachMeetingUsesAnIndependentUUIDDirectory() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let firstID = UUID()
        let secondID = UUID()

        let firstDirectory = try await store.prepareMeetingDirectory(for: firstID)
        let secondDirectory = try await store.prepareMeetingDirectory(for: secondID)

        XCTAssertEqual(firstDirectory.lastPathComponent, firstID.uuidString)
        XCTAssertEqual(secondDirectory.lastPathComponent, secondID.uuidString)
        XCTAssertNotEqual(firstDirectory, secondDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    func testManifestIsWrittenAtomicallyAndReloaded() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let manifest = AudioSegmentManifest(
            segments: [
                .init(
                    fileName: "segment-0001.caf",
                    startTime: 0,
                    endTime: 12.5,
                    frameCount: 200_000,
                    isComplete: true
                )
            ]
        )

        try await store.saveManifest(AudioSegmentManifest(), meetingID: meetingID)
        try await store.saveManifest(manifest, meetingID: meetingID)
        let reloaded = try await store.loadManifest(meetingID: meetingID)

        XCTAssertEqual(reloaded, manifest)
        let meetingDirectory = root.appendingPathComponent(meetingID.uuidString)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: meetingDirectory.path),
            [MeetingFileStore.manifestFileName]
        )
    }

    func testResolveAcceptsOnlyPathsInsideRoot() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let relativePath = "\(meetingID.uuidString)/\(MeetingFileStore.manifestFileName)"

        let resolved = try await store.resolve(relativePath: relativePath)

        XCTAssertEqual(
            resolved,
            root.appendingPathComponent(relativePath).standardizedFileURL
        )

        await XCTAssertThrowsErrorAsync(
            try await store.resolve(relativePath: "../outside.json")
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath("../outside.json")
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await store.resolve(relativePath: "/tmp/outside.json")
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath("/tmp/outside.json")
            )
        }
    }

    func testResolveRejectsExistingSymlinkEscape() async throws {
        let root = try makeTemporaryRoot()
        let outside = try makeTemporaryRoot()
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = MeetingFileStore(rootURL: root)

        await XCTAssertThrowsErrorAsync(
            try await store.resolve(relativePath: "linked/manifest.json")
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath("linked/manifest.json")
            )
        }
    }

    func testDeletingOneMeetingDoesNotAffectAnother() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let firstID = UUID()
        let secondID = UUID()
        let manifest = AudioSegmentManifest()
        try await store.saveManifest(manifest, meetingID: firstID)
        try await store.saveManifest(manifest, meetingID: secondID)

        try await store.deleteMeetingDirectory(for: firstID)

        await XCTAssertThrowsErrorAsync(
            try await store.loadManifest(meetingID: firstID)
        ) { error in
            XCTAssertEqual(error as? MeetingFileStoreError, .manifestNotFound(firstID))
        }
        let secondManifest = try await store.loadManifest(meetingID: secondID)
        XCTAssertEqual(secondManifest, manifest)
    }

    func testDeleteRejectsMeetingDirectorySymlinkWithoutDeletingItsTarget() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let linkedID = UUID()
        let targetID = UUID()
        let targetDirectory = try await store.prepareMeetingDirectory(
            for: targetID
        )
        let sentinel = targetDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let link = root.appendingPathComponent(linkedID.uuidString)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: targetDirectory
        )

        await XCTAssertThrowsErrorAsync(
            try await store.deleteMeetingDirectory(for: linkedID)
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath(linkedID.uuidString)
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "拒绝删除符号链接时，链接目标会议目录必须完整保留"
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
