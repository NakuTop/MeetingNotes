import XCTest
@testable import MeetingNotes

final class TranscriptionModelFileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptionModelFileStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func testCompleteDownloadIsInstalledAtomicallyInDedicatedFolder()
        throws {
        let source = root.appendingPathComponent("download", isDirectory: true)
        let destination = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("high-accuracy", isDirectory: true)
        try makeCompleteModel(at: source, marker: "new")

        try TranscriptionModelFileStore().installModel(
            from: source,
            to: destination
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("config.json").path
            )
        )
        XCTAssertEqual(try marker(at: destination), "new")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
                    .path
            )
        )
        XCTAssertTrue(try stagingDirectories(beside: destination).isEmpty)
    }

    func testCompleteDownloadAtomicallyReplacesExistingModel() throws {
        let source = root.appendingPathComponent("download", isDirectory: true)
        let destination = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("high-accuracy", isDirectory: true)
        try makeCompleteModel(at: source, marker: "new")
        try makeCompleteModel(at: destination, marker: "old")

        try TranscriptionModelFileStore().installModel(
            from: source,
            to: destination
        )

        XCTAssertEqual(try marker(at: destination), "new")
        XCTAssertTrue(try stagingDirectories(beside: destination).isEmpty)
    }

    func testFailureBeforeStagingCompletesLeavesNoDestinationOrTemporaryFolder()
        throws {
        let source = root.appendingPathComponent("download", isDirectory: true)
        let destination = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("balanced", isDirectory: true)
        try makeCompleteModel(at: source, marker: "new")
        let store = TranscriptionModelFileStore { checkpoint in
            if checkpoint == .stagingDirectoryCreated {
                throw TranscriptionModelFileStoreTestError.injected
            }
        }

        XCTAssertThrowsError(
            try store.installModel(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? TranscriptionModelFileStoreTestError,
                .injected
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
        XCTAssertTrue(try stagingDirectories(beside: destination).isEmpty)
    }

    func testFailureBeforeCommitPreservesExistingDestinationAndCleansStaging()
        throws {
        let source = root.appendingPathComponent("download", isDirectory: true)
        let destination = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("balanced", isDirectory: true)
        try makeCompleteModel(at: source, marker: "new")
        try makeCompleteModel(at: destination, marker: "old")
        let store = TranscriptionModelFileStore { checkpoint in
            if checkpoint == .readyToCommit {
                throw TranscriptionModelFileStoreTestError.injected
            }
        }

        XCTAssertThrowsError(
            try store.installModel(from: source, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? TranscriptionModelFileStoreTestError,
                .injected
            )
        }

        XCTAssertEqual(try marker(at: destination), "old")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
                    .path
            )
        )
        XCTAssertTrue(try stagingDirectories(beside: destination).isEmpty)
    }

    private func makeCompleteModel(at folder: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("config.json")
        )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(
                "Encoder.mlmodelc",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try Data(marker.utf8).write(
            to: folder.appendingPathComponent("marker.txt")
        )
    }

    private func marker(at folder: URL) throws -> String {
        try String(
            contentsOf: folder.appendingPathComponent("marker.txt"),
            encoding: .utf8
        )
    }

    private func stagingDirectories(beside destination: URL) throws -> [URL] {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(
                ".\(destination.lastPathComponent).staging-"
            )
        }
    }
}

private enum TranscriptionModelFileStoreTestError: Error, Equatable {
    case injected
}
