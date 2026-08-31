import XCTest
@testable import MeetingNotes

final class MeetingFileStoreTests: XCTestCase {
    func testAudioTracksUseExactManifestAndSegmentNames() {
        XCTAssertEqual(AudioTrack.allCases, [.master, .microphone, .system])
        XCTAssertEqual(AudioTrack.allCases.map(\.rawValue), [
            "master",
            "microphone",
            "system"
        ])
        XCTAssertEqual(AudioTrack.master.manifestFileName, "manifest.json")
        XCTAssertEqual(AudioTrack.master.segmentFileNamePrefix, "segment")
        XCTAssertEqual(
            AudioTrack.microphone.manifestFileName,
            "microphone-manifest.json"
        )
        XCTAssertEqual(
            AudioTrack.microphone.segmentFileNamePrefix,
            "microphone-segment"
        )
        XCTAssertEqual(
            AudioTrack.system.manifestFileName,
            "system-manifest.json"
        )
        XCTAssertEqual(
            AudioTrack.system.segmentFileNamePrefix,
            "system-segment"
        )
        XCTAssertEqual(
            MeetingFileStore.manifestFileName,
            AudioTrack.master.manifestFileName
        )
    }

    func testTrackManifestsAreStoredIndependentlyAndDefaultToMaster() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let master = AudioSegmentManifest(segments: [
            segment(fileName: "segment-0001.caf", frameCount: 1)
        ])
        let microphone = AudioSegmentManifest(segments: [
            segment(fileName: "microphone-segment-0001.caf", frameCount: 2)
        ])
        let system = AudioSegmentManifest(segments: [
            segment(fileName: "system-segment-0001.caf", frameCount: 3)
        ])

        try await store.saveManifest(master, meetingID: meetingID)
        try await store.saveManifest(
            microphone,
            meetingID: meetingID,
            track: .microphone
        )
        try await store.saveManifest(
            system,
            meetingID: meetingID,
            track: .system
        )

        let reloadedMaster = try await store.loadManifest(meetingID: meetingID)
        let reloadedMicrophone = try await store.loadManifest(
            meetingID: meetingID,
            track: .microphone
        )
        let reloadedSystem = try await store.loadManifest(
            meetingID: meetingID,
            track: .system
        )
        XCTAssertEqual(reloadedMaster, master)
        XCTAssertEqual(reloadedMicrophone, microphone)
        XCTAssertEqual(reloadedSystem, system)

        let masterPath = await store.relativeManifestPath(for: meetingID)
        let microphonePath = await store.relativeManifestPath(
            for: meetingID,
            track: .microphone
        )
        let systemPath = await store.relativeManifestPath(
            for: meetingID,
            track: .system
        )
        XCTAssertEqual(masterPath, "\(meetingID.uuidString)/manifest.json")
        XCTAssertEqual(
            microphonePath,
            "\(meetingID.uuidString)/microphone-manifest.json"
        )
        XCTAssertEqual(
            systemPath,
            "\(meetingID.uuidString)/system-manifest.json"
        )

        let meetingDirectory = root.appendingPathComponent(meetingID.uuidString)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(
                atPath: meetingDirectory.path
            )),
            Set([
                "manifest.json",
                "microphone-manifest.json",
                "system-manifest.json"
            ])
        )
    }

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

    func testSaveScreenshotWritesAtomicallyUnderMeetingDirectory() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let screenshotID = UUID()
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])

        let relativePath = try await store.saveScreenshotPNG(
            pngData,
            meetingID: meetingID,
            screenshotID: screenshotID
        )

        XCTAssertEqual(
            relativePath,
            "\(meetingID.uuidString)/screenshots/\(screenshotID.uuidString).png"
        )
        let destination = root.appendingPathComponent(relativePath)
        XCTAssertEqual(try Data(contentsOf: destination), pngData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.deletingLastPathComponent().path
            ),
            ["\(screenshotID.uuidString).png"]
        )
    }

    func testResolveScreenshotRejectsTraversalAndSymlinks() async throws {
        let root = try makeTemporaryRoot()
        let outside = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let screenshotID = UUID()
        let relativePath = try await store.saveScreenshotPNG(
            Data([1, 2, 3]),
            meetingID: meetingID,
            screenshotID: screenshotID
        )

        let resolved = try await store.resolveScreenshotURL(
            meetingID: meetingID,
            relativePath: relativePath
        )
        XCTAssertEqual(resolved, root.appendingPathComponent(relativePath))

        let traversal = "\(meetingID.uuidString)/screenshots/../outside.png"
        await XCTAssertThrowsErrorAsync(
            try await store.resolveScreenshotURL(
                meetingID: meetingID,
                relativePath: traversal
            )
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath(traversal)
            )
        }

        let outsideFile = outside.appendingPathComponent("outside.png")
        try Data([9, 9, 9]).write(to: outsideFile)
        let symlinkName = "\(UUID().uuidString).png"
        let symlinkRelativePath =
            "\(meetingID.uuidString)/screenshots/\(symlinkName)"
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(symlinkRelativePath),
            withDestinationURL: outsideFile
        )

        await XCTAssertThrowsErrorAsync(
            try await store.resolveScreenshotURL(
                meetingID: meetingID,
                relativePath: symlinkRelativePath
            )
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath(symlinkRelativePath)
            )
        }

        let linkedMeetingID = UUID()
        let linkedMeetingDirectory = root.appendingPathComponent(
            linkedMeetingID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedMeetingDirectory,
            withIntermediateDirectories: false
        )
        let linkedScreenshotsDirectory = linkedMeetingDirectory
            .appendingPathComponent("screenshots")
        try FileManager.default.createSymbolicLink(
            at: linkedScreenshotsDirectory,
            withDestinationURL: outside
        )
        let linkedFileName = "\(UUID().uuidString).png"
        try Data([8, 8, 8]).write(
            to: outside.appendingPathComponent(linkedFileName)
        )
        let linkedRelativePath =
            "\(linkedMeetingID.uuidString)/screenshots/\(linkedFileName)"

        await XCTAssertThrowsErrorAsync(
            try await store.resolveScreenshotURL(
                meetingID: linkedMeetingID,
                relativePath: linkedRelativePath
            )
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .invalidRelativePath(
                    "\(linkedMeetingID.uuidString)/screenshots"
                )
            )
        }
    }

    func testFailedScreenshotWriteLeavesNoDestination() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let screenshotID = UUID()
        let meetingDirectory = try await store.prepareMeetingDirectory(
            for: meetingID
        )
        let screenshotsBlocker = meetingDirectory.appendingPathComponent(
            "screenshots"
        )
        try Data("not-a-directory".utf8).write(to: screenshotsBlocker)

        await XCTAssertThrowsErrorAsync(
            try await store.saveScreenshotPNG(
                Data([1, 2, 3]),
                meetingID: meetingID,
                screenshotID: screenshotID
            )
        )

        let destination = screenshotsBlocker.appendingPathComponent(
            "\(screenshotID.uuidString).png"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: meetingDirectory.path
            ),
            ["screenshots"]
        )
    }

    func testStagedScreenshotDeletionCanRollbackOrCommit() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let screenshotID = UUID()
        let data = Data([4, 5, 6])
        let relativePath = try await store.saveScreenshotPNG(
            data,
            meetingID: meetingID,
            screenshotID: screenshotID
        )
        let originalURL = root.appendingPathComponent(relativePath)

        let stagedForRollback = try await store.stageScreenshotDeletion(
            meetingID: meetingID,
            relativePath: relativePath
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))

        try await store.rollbackScreenshotDeletion(stagedForRollback)
        XCTAssertEqual(try Data(contentsOf: originalURL), data)

        let stagedForCommit = try await store.stageScreenshotDeletion(
            meetingID: meetingID,
            relativePath: relativePath
        )
        try await store.commitScreenshotDeletion(stagedForCommit)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: originalURL.deletingLastPathComponent().path
            ),
            []
        )
    }

    func testStagedScreenshotDeletionRejectsReplacedFile() async throws {
        let root = try makeTemporaryRoot()
        let store = MeetingFileStore(rootURL: root)
        let meetingID = UUID()
        let relativePath = try await store.saveScreenshotPNG(
            Data([1, 2, 3]),
            meetingID: meetingID,
            screenshotID: UUID()
        )
        let staged = try await store.stageScreenshotDeletion(
            meetingID: meetingID,
            relativePath: relativePath
        )
        let stagedURL = root.appendingPathComponent(staged.stagedRelativePath)
        try FileManager.default.removeItem(at: stagedURL)
        try Data([9, 9, 9]).write(to: stagedURL)

        await XCTAssertThrowsErrorAsync(
            try await store.commitScreenshotDeletion(staged)
        ) { error in
            XCTAssertEqual(
                error as? MeetingFileStoreError,
                .screenshotIdentityChanged
            )
        }

        XCTAssertEqual(try Data(contentsOf: stagedURL), Data([9, 9, 9]))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relativePath).path
            )
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

    private func segment(
        fileName: String,
        frameCount: Int64
    ) -> AudioSegmentManifest.Segment {
        .init(
            fileName: fileName,
            startTime: 0,
            endTime: Double(frameCount) / 16_000,
            frameCount: frameCount,
            isComplete: true
        )
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
