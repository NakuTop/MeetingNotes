import Foundation

struct TranscriptionModelStorage: Sendable {
    let modelsRoot: URL
    let legacyModelFolder: URL?

    func folder(for mode: TranscriptionQualityMode) -> URL {
        let descriptor = TranscriptionModelCatalog.descriptor(for: mode)
        return folder(for: descriptor)
    }

    private func folder(for descriptor: TranscriptionModelDescriptor) -> URL {
        return modelsRoot
            .appendingPathComponent(
                Self.encodedPathComponent(descriptor.directoryName),
                isDirectory: true
            )
            .appendingPathComponent(
                Self.encodedPathComponent(descriptor.modelID),
                isDirectory: true
            )
    }

    func resolvedFolder(
        for descriptor: TranscriptionModelDescriptor
    ) throws -> URL {
        let destination = folder(for: descriptor)
        guard !hasCompleteModel(at: destination) else {
            return destination
        }
        guard descriptor.mode == .balanced,
              let legacyModelFolder,
              hasCompleteModel(at: legacyModelFolder) else {
            return destination
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: legacyModelFolder,
                to: destination
            )
            return destination
        } catch {
            if hasCompleteModel(at: legacyModelFolder) {
                return legacyModelFolder
            }
            throw error
        }
    }

    func hasCompleteModel(at folder: URL) -> Bool {
        TranscriptionModelFileStore().hasCompleteModel(at: folder)
    }

    private static func encodedPathComponent(_ value: String) -> String {
        guard !value.isEmpty else {
            return "%EMPTY"
        }
        return value.utf8.reduce(into: "") { result, byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 95:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
    }
}
