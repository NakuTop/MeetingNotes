import Foundation

enum TranscriptionModelFileStoreCheckpoint: Equatable, Sendable {
    case stagingDirectoryCreated
    case readyToCommit
}

enum TranscriptionModelFileStoreError: Error, Equatable, Sendable {
    case incompleteModel
}

struct TranscriptionModelFileStore: Sendable {
    typealias FailureInjector = @Sendable (
        TranscriptionModelFileStoreCheckpoint
    ) throws -> Void

    private let failureInjector: FailureInjector

    init(
        failureInjector: @escaping FailureInjector = { _ in }
    ) {
        self.failureInjector = failureInjector
    }

    func installModel(from source: URL, to destination: URL) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source != destination else {
            return
        }

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            try failureInjector(.stagingDirectoryCreated)

            let contents = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )
            for item in contents {
                try fileManager.copyItem(
                    at: item,
                    to: staging.appendingPathComponent(item.lastPathComponent)
                )
            }

            guard hasCompleteModel(at: staging) else {
                throw TranscriptionModelFileStoreError.incompleteModel
            }
            try failureInjector(.readyToCommit)

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging
                )
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func hasCompleteModel(at folder: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }

        let configURL = folder.appendingPathComponent("config.json")
        guard (try? configURL.resourceValues(
            forKeys: [.isRegularFileKey]
        ).isRegularFile) == true,
              let contents = try? fileManager.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return false
        }
        return contents.contains {
            $0.pathExtension == "mlmodelc"
                && (try? $0.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
        }
    }
}
