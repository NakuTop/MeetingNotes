import XCTest
@testable import MeetingNotes

final class TranscriptionModelStorageTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptionModelStorageTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testHighAccuracyAndBalancedUseDifferentFolders() throws {
        let storage = makeStorage()

        let balanced = storage.folder(for: .balanced)
        let highAccuracy = storage.folder(for: .highAccuracy)

        XCTAssertNotEqual(balanced, highAccuracy)
        XCTAssertEqual(
            balanced.pathComponents.suffix(2),
            [
                "balanced",
                "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page",
            ]
        )
        XCTAssertEqual(
            highAccuracy.pathComponents.suffix(2),
            ["high-accuracy", "openai_whisper-large-v3-v20240930_626MB"]
        )
    }

    func testResolvedFolderSanitizesDescriptorModelID() throws {
        let storage = makeStorage()
        let descriptor = TranscriptionModelDescriptor(
            mode: .highAccuracy,
            modelID: "owner/model:unsafe",
            directoryName: "high-accuracy",
            detail: "test"
        )

        let resolved = try storage.resolvedFolder(for: descriptor)

        XCTAssertEqual(
            resolved.pathComponents.suffix(2),
            ["high-accuracy", "owner%2Fmodel%3Aunsafe"]
        )
    }

    func testUnsafeModelIDsUseDistinctEncodedFolders() throws {
        let storage = makeStorage()
        let slashDescriptor = TranscriptionModelDescriptor(
            mode: .highAccuracy,
            modelID: "owner/model",
            directoryName: "high-accuracy",
            detail: "test"
        )
        let colonDescriptor = TranscriptionModelDescriptor(
            mode: .highAccuracy,
            modelID: "owner:model",
            directoryName: "high-accuracy",
            detail: "test"
        )

        let slashFolder = try storage.resolvedFolder(for: slashDescriptor)
        let colonFolder = try storage.resolvedFolder(for: colonDescriptor)

        XCTAssertNotEqual(slashFolder, colonFolder)
        XCTAssertEqual(slashFolder.lastPathComponent, "owner%2Fmodel")
        XCTAssertEqual(colonFolder.lastPathComponent, "owner%3Amodel")
    }

    func testResolvedFolderKeepsUnsafeDirectoryNameInsideModelsRoot() throws {
        let storage = makeStorage()
        let descriptor = TranscriptionModelDescriptor(
            mode: .highAccuracy,
            modelID: "model",
            directoryName: "../outside",
            detail: "test"
        )

        let resolved = try storage.resolvedFolder(for: descriptor)
        let standardizedRoot = storage.modelsRoot.standardizedFileURL.path
        let standardizedResolved = resolved.standardizedFileURL.path

        XCTAssertTrue(standardizedResolved.hasPrefix(standardizedRoot + "/"))
        XCTAssertFalse(resolved.pathComponents.contains(".."))
        XCTAssertEqual(
            resolved.pathComponents.suffix(2),
            ["%2E%2E%2Foutside", "model"]
        )
    }

    func testAdoptsCompleteLegacyCacheForBalancedOnly() throws {
        let legacy = temporaryRoot.appendingPathComponent(
            "WhisperModels",
            isDirectory: true
        )
        try makeCompleteModel(at: legacy)
        let storage = makeStorage(legacy: legacy)
        let balancedDescriptor = TranscriptionModelCatalog.descriptor(
            for: .balanced
        )

        let resolved = try storage.resolvedFolder(for: balancedDescriptor)

        XCTAssertEqual(resolved, storage.folder(for: .balanced))
        XCTAssertTrue(storage.hasCompleteModel(at: resolved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        let secondLegacy = temporaryRoot.appendingPathComponent(
            "SecondLegacy",
            isDirectory: true
        )
        try makeCompleteModel(at: secondLegacy)
        let secondStorage = TranscriptionModelStorage(
            modelsRoot: temporaryRoot.appendingPathComponent(
                "SecondWhisperModels-v2",
                isDirectory: true
            ),
            legacyModelFolder: secondLegacy
        )
        let highAccuracyDescriptor = TranscriptionModelCatalog.descriptor(
            for: .highAccuracy
        )

        let highAccuracyResolved = try secondStorage.resolvedFolder(
            for: highAccuracyDescriptor
        )

        XCTAssertEqual(
            highAccuracyResolved,
            secondStorage.folder(for: .highAccuracy)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: secondLegacy.appendingPathComponent("config.json").path
            )
        )
        XCTAssertFalse(secondStorage.hasCompleteModel(at: highAccuracyResolved))
    }

    func testExistingDestinationWinsWithoutDeletingLegacyCache() throws {
        let legacy = temporaryRoot.appendingPathComponent(
            "WhisperModels",
            isDirectory: true
        )
        let storage = makeStorage(legacy: legacy)
        let destination = storage.folder(for: .balanced)
        try makeCompleteModel(at: legacy)
        try makeCompleteModel(at: destination)

        let resolved = try storage.resolvedFolder(
            for: TranscriptionModelCatalog.descriptor(for: .balanced)
        )

        XCTAssertEqual(resolved, destination)
        XCTAssertTrue(storage.hasCompleteModel(at: destination))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("config.json").path
            )
        )
    }

    func testIncompleteLegacyCacheIsNotMarkedAvailable() throws {
        let legacy = temporaryRoot.appendingPathComponent(
            "WhisperModels",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: legacy.appendingPathComponent("config.json")
        )
        let storage = makeStorage(legacy: legacy)

        let resolved = try storage.resolvedFolder(
            for: TranscriptionModelCatalog.descriptor(for: .balanced)
        )

        XCTAssertEqual(resolved, storage.folder(for: .balanced))
        XCTAssertFalse(storage.hasCompleteModel(at: resolved))
        XCTAssertFalse(storage.hasCompleteModel(at: legacy))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("config.json").path
            )
        )
    }

    func testFailedAdoptionLeavesLegacyCacheIntact() throws {
        let legacy = temporaryRoot.appendingPathComponent(
            "WhisperModels",
            isDirectory: true
        )
        try makeCompleteModel(at: legacy)
        let blockedRoot = temporaryRoot.appendingPathComponent(
            "WhisperModels-v2"
        )
        try Data("not a directory".utf8).write(to: blockedRoot)
        let storage = TranscriptionModelStorage(
            modelsRoot: blockedRoot,
            legacyModelFolder: legacy
        )

        let resolved = try storage.resolvedFolder(
            for: TranscriptionModelCatalog.descriptor(for: .balanced)
        )

        XCTAssertEqual(resolved, legacy)
        XCTAssertTrue(storage.hasCompleteModel(at: legacy))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("config.json").path
            )
        )
    }

    func testMoveFailureFromExistingDestinationKeepsLegacyIntact() throws {
        let legacy = temporaryRoot.appendingPathComponent(
            "WhisperModels",
            isDirectory: true
        )
        try makeCompleteModel(at: legacy)
        let storage = makeStorage(legacy: legacy)
        let destination = storage.folder(for: .balanced)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let destinationMarker = destination.appendingPathComponent(
            "partial-download"
        )
        try Data("keep destination".utf8).write(to: destinationMarker)

        let resolved = try storage.resolvedFolder(
            for: TranscriptionModelCatalog.descriptor(for: .balanced)
        )

        XCTAssertEqual(resolved, legacy)
        XCTAssertTrue(storage.hasCompleteModel(at: legacy))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("config.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent(
                    "AudioEncoder.mlmodelc",
                    isDirectory: true
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destinationMarker.path)
        )
        XCTAssertFalse(storage.hasCompleteModel(at: destination))
    }

    private func makeStorage(
        legacy: URL? = nil
    ) -> TranscriptionModelStorage {
        TranscriptionModelStorage(
            modelsRoot: temporaryRoot.appendingPathComponent(
                "WhisperModels-v2",
                isDirectory: true
            ),
            legacyModelFolder: legacy
        )
    }

    private func makeCompleteModel(at folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("config.json")
        )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(
                "AudioEncoder.mlmodelc",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }
}
