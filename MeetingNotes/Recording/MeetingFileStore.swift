import Darwin
import Foundation

enum MeetingFileStoreError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case manifestNotFound(UUID)
    case waveformNotFound(UUID)
    case segmentNotFound
    case segmentIdentityChanged
}

struct MeetingRecordingFileIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let inodeNumber: UInt64
}

struct ResolvedMeetingRecordingSegment: Equatable, Sendable {
    let url: URL
    let fileIdentity: MeetingRecordingFileIdentity
    let meetingDirectoryIdentity: MeetingRecordingFileIdentity
}

actor MeetingFileStore {
    static let manifestFileName = "manifest.json"
    static let waveformFileName = "waveform-v1.json"

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

    func saveWaveformSnapshot(
        _ snapshot: WaveformSnapshot,
        meetingID: UUID
    ) throws {
        let directory = try prepareMeetingDirectory(for: meetingID)
        let destination = directory.appendingPathComponent(Self.waveformFileName)
        let temporary = directory.appendingPathComponent(
            ".waveform-\(UUID().uuidString).tmp"
        )
        let data = try encoder.encode(snapshot)

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

    func loadWaveformSnapshot(meetingID: UUID) throws -> WaveformSnapshot {
        let relativePath = "\(meetingID.uuidString)/\(Self.waveformFileName)"
        let url = try resolve(relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MeetingFileStoreError.waveformNotFound(meetingID)
        }
        return try decoder.decode(
            WaveformSnapshot.self,
            from: Data(contentsOf: url)
        )
    }

    func relativeManifestPath(for meetingID: UUID) -> String {
        "\(meetingID.uuidString)/\(Self.manifestFileName)"
    }

    func resolveSegmentURL(meetingID: UUID, fileName: String) throws -> URL {
        try resolveSegment(meetingID: meetingID, fileName: fileName).url
    }

    func resolveSegment(
        meetingID: UUID,
        fileName: String
    ) throws -> ResolvedMeetingRecordingSegment {
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
        let meetingIdentity = try identity(
            at: expectedMeetingDirectory,
            expectedFileType: mode_t(S_IFDIR),
            missingError: .segmentNotFound,
            invalidError: .invalidRelativePath(fileName)
        )
        let segmentURL = expectedMeetingDirectory
            .appendingPathComponent(fileName)
            .standardizedFileURL
        let fileIdentity = try identity(
            at: segmentURL,
            expectedFileType: mode_t(S_IFREG),
            missingError: .segmentNotFound,
            invalidError: .invalidRelativePath(fileName)
        )
        return ResolvedMeetingRecordingSegment(
            url: segmentURL,
            fileIdentity: fileIdentity,
            meetingDirectoryIdentity: meetingIdentity
        )
    }

    func confirmIdentity(
        of segment: ResolvedMeetingRecordingSegment
    ) throws {
        let directoryURL = segment.url.deletingLastPathComponent()
        let currentDirectoryIdentity: MeetingRecordingFileIdentity
        let currentFileIdentity: MeetingRecordingFileIdentity
        do {
            currentDirectoryIdentity = try identity(
                at: directoryURL,
                expectedFileType: mode_t(S_IFDIR),
                missingError: .segmentIdentityChanged,
                invalidError: .segmentIdentityChanged
            )
            currentFileIdentity = try identity(
                at: segment.url,
                expectedFileType: mode_t(S_IFREG),
                missingError: .segmentIdentityChanged,
                invalidError: .segmentIdentityChanged
            )
        } catch {
            throw MeetingFileStoreError.segmentIdentityChanged
        }

        guard currentDirectoryIdentity == segment.meetingDirectoryIdentity,
              currentFileIdentity == segment.fileIdentity else {
            throw MeetingFileStoreError.segmentIdentityChanged
        }
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

    private func identity(
        at url: URL,
        expectedFileType: mode_t,
        missingError: MeetingFileStoreError,
        invalidError: MeetingFileStoreError
    ) throws -> MeetingRecordingFileIdentity {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw missingError
            }
            throw invalidError
        }

        let actualFileType = information.st_mode & mode_t(S_IFMT)
        guard actualFileType == expectedFileType else {
            throw invalidError
        }
        return MeetingRecordingFileIdentity(
            deviceID: UInt64(bitPattern: Int64(information.st_dev)),
            inodeNumber: UInt64(information.st_ino)
        )
    }
}
