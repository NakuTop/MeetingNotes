import Foundation

enum MeetingFileStoreError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case manifestNotFound(UUID)
}

actor MeetingFileStore {
    static let manifestFileName = "manifest.json"

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    func prepareMeetingDirectory(for meetingID: UUID) throws -> URL {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let directory = try resolve(relativePath: meetingID.uuidString)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func saveManifest(
        _ manifest: AudioSegmentManifest,
        meetingID: UUID
    ) throws {
        let directory = try prepareMeetingDirectory(for: meetingID)
        let destination = directory.appendingPathComponent(Self.manifestFileName)
        let temporary = directory.appendingPathComponent(
            ".manifest-\(UUID().uuidString).tmp"
        )
        let data = try encoder.encode(manifest)

        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func loadManifest(meetingID: UUID) throws -> AudioSegmentManifest {
        let relativePath = "\(meetingID.uuidString)/\(Self.manifestFileName)"
        let url = try resolve(relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingFileStoreError.manifestNotFound(meetingID)
        }
        return try decoder.decode(
            AudioSegmentManifest.self,
            from: Data(contentsOf: url)
        )
    }

    func relativeManifestPath(for meetingID: UUID) -> String {
        "\(meetingID.uuidString)/\(Self.manifestFileName)"
    }

    func resolveSegmentURL(meetingID: UUID, fileName: String) throws -> URL {
        let path = fileName as NSString
        guard !fileName.isEmpty,
              !path.isAbsolutePath,
              path.pathComponents.count == 1,
              path.lastPathComponent == fileName,
              fileName != ".",
              fileName != ".." else {
            throw MeetingFileStoreError.invalidRelativePath(fileName)
        }

        let expectedMeetingDirectory = rootURL
            .appendingPathComponent(meetingID.uuidString)
            .standardizedFileURL
        let meetingDirectory = try resolve(relativePath: meetingID.uuidString)
        guard meetingDirectory.path == expectedMeetingDirectory.path else {
            throw MeetingFileStoreError.invalidRelativePath(fileName)
        }
        let segmentURL = try resolve(
            relativePath: "\(meetingID.uuidString)/\(fileName)"
        )
        guard segmentURL.deletingLastPathComponent().path
                == expectedMeetingDirectory.path else {
            throw MeetingFileStoreError.invalidRelativePath(fileName)
        }
        return segmentURL
    }

    func resolve(relativePath: String) throws -> URL {
        let path = relativePath as NSString
        guard !relativePath.isEmpty, !path.isAbsolutePath else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }

        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard isWithinRoot(candidate) else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }

        var existingAncestor = candidate
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != rootURL.path {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }

        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath()
        let resolvedCandidate = missingComponents.reduce(resolvedAncestor) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL

        guard isWithinRoot(resolvedCandidate) else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }
        return resolvedCandidate
    }

    func deleteMeetingDirectory(for meetingID: UUID) throws {
        let directory = try resolve(relativePath: meetingID.uuidString)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    private func isWithinRoot(_ url: URL) -> Bool {
        url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
    }
}
