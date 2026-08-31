import Darwin
import Foundation

enum MeetingFileStoreError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case manifestNotFound(UUID)
    case waveformNotFound(UUID)
    case screenshotNotFound
    case screenshotIdentityChanged
    case screenshotDestinationExists
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

struct StagedScreenshotDeletion: Equatable, Sendable {
    let meetingID: UUID
    let originalRelativePath: String
    let stagedRelativePath: String
    let fileIdentity: MeetingRecordingFileIdentity
}

actor MeetingFileStore {
    static let manifestFileName = AudioTrack.master.manifestFileName
    static let waveformFileName = "waveform-v1.json"
    static let screenshotDirectoryName = "screenshots"

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
        meetingID: UUID,
        track: AudioTrack = .master
    ) throws {
        let directory = try prepareMeetingDirectory(for: meetingID)
        let destination = directory.appendingPathComponent(track.manifestFileName)
        let temporary = directory.appendingPathComponent(
            ".\(track.rawValue)-manifest-\(UUID().uuidString).tmp"
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

    func loadManifest(
        meetingID: UUID,
        track: AudioTrack = .master
    ) throws -> AudioSegmentManifest {
        let relativePath = "\(meetingID.uuidString)/\(track.manifestFileName)"
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

    func saveScreenshotPNG(
        _ data: Data,
        meetingID: UUID,
        screenshotID: UUID
    ) throws -> String {
        let directory = try prepareScreenshotDirectory(for: meetingID)
        let fileName = "\(screenshotID.uuidString).png"
        let destination = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent(
            ".screenshot-\(UUID().uuidString).tmp"
        )

        guard !fileSystemEntryExists(at: destination) else {
            throw MeetingFileStoreError.screenshotDestinationExists
        }

        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        return screenshotRelativePath(
            meetingID: meetingID,
            fileName: fileName
        )
    }

    func resolveScreenshotURL(
        meetingID: UUID,
        relativePath: String
    ) throws -> URL {
        let fileName = try validatedScreenshotFileName(
            meetingID: meetingID,
            relativePath: relativePath
        )
        let directory = try existingScreenshotDirectory(for: meetingID)
        let url = directory.appendingPathComponent(fileName)
        _ = try identity(
            at: url,
            expectedFileType: mode_t(S_IFREG),
            missingError: .screenshotNotFound,
            invalidError: .invalidRelativePath(relativePath)
        )
        return url
    }

    func stageScreenshotDeletion(
        meetingID: UUID,
        relativePath: String
    ) throws -> StagedScreenshotDeletion {
        let originalURL = try resolveScreenshotURL(
            meetingID: meetingID,
            relativePath: relativePath
        )
        let originalIdentity = try identity(
            at: originalURL,
            expectedFileType: mode_t(S_IFREG),
            missingError: .screenshotNotFound,
            invalidError: .invalidRelativePath(relativePath)
        )
        let stagedFileName =
            ".screenshot-delete-\(UUID().uuidString).tmp"
        let stagedRelativePath = screenshotRelativePath(
            meetingID: meetingID,
            fileName: stagedFileName
        )
        let stagedURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(stagedFileName)
        guard !fileSystemEntryExists(at: stagedURL) else {
            throw MeetingFileStoreError.screenshotDestinationExists
        }

        try fileManager.moveItem(at: originalURL, to: stagedURL)
        return StagedScreenshotDeletion(
            meetingID: meetingID,
            originalRelativePath: relativePath,
            stagedRelativePath: stagedRelativePath,
            fileIdentity: originalIdentity
        )
    }

    func rollbackScreenshotDeletion(
        _ staged: StagedScreenshotDeletion
    ) throws {
        let urls = try validatedStagedScreenshotDeletion(staged)
        guard !fileSystemEntryExists(at: urls.original) else {
            throw MeetingFileStoreError.screenshotDestinationExists
        }
        try fileManager.moveItem(at: urls.staged, to: urls.original)
        let restoredIdentity = try identity(
            at: urls.original,
            expectedFileType: mode_t(S_IFREG),
            missingError: .screenshotIdentityChanged,
            invalidError: .screenshotIdentityChanged
        )
        guard restoredIdentity == staged.fileIdentity else {
            throw MeetingFileStoreError.screenshotIdentityChanged
        }
    }

    func commitScreenshotDeletion(
        _ staged: StagedScreenshotDeletion
    ) throws {
        let urls = try validatedStagedScreenshotDeletion(staged)
        try fileManager.removeItem(at: urls.staged)
    }

    func relativeManifestPath(
        for meetingID: UUID,
        track: AudioTrack = .master
    ) -> String {
        "\(meetingID.uuidString)/\(track.manifestFileName)"
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
        let relativePath = meetingID.uuidString
        let directory = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard isWithinRoot(directory) else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }
        do {
            _ = try identity(
                at: directory,
                expectedFileType: mode_t(S_IFDIR),
                missingError: .segmentNotFound,
                invalidError: .invalidRelativePath(relativePath)
            )
        } catch MeetingFileStoreError.segmentNotFound {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    private func isWithinRoot(_ url: URL) -> Bool {
        url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
    }

    private func prepareScreenshotDirectory(for meetingID: UUID) throws -> URL {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        _ = try identity(
            at: rootURL,
            expectedFileType: mode_t(S_IFDIR),
            missingError: .invalidRelativePath(meetingID.uuidString),
            invalidError: .invalidRelativePath(meetingID.uuidString)
        )

        let meetingDirectory = rootURL.appendingPathComponent(
            meetingID.uuidString,
            isDirectory: true
        )
        try ensureDirectory(
            at: meetingDirectory,
            invalidPath: meetingID.uuidString
        )
        let screenshotsDirectory = meetingDirectory.appendingPathComponent(
            Self.screenshotDirectoryName,
            isDirectory: true
        )
        try ensureDirectory(
            at: screenshotsDirectory,
            invalidPath: screenshotDirectoryRelativePath(for: meetingID)
        )
        return screenshotsDirectory
    }

    private func existingScreenshotDirectory(for meetingID: UUID) throws -> URL {
        let meetingPath = meetingID.uuidString
        let meetingDirectory = rootURL.appendingPathComponent(
            meetingPath,
            isDirectory: true
        )
        _ = try identity(
            at: meetingDirectory,
            expectedFileType: mode_t(S_IFDIR),
            missingError: .screenshotNotFound,
            invalidError: .invalidRelativePath(meetingPath)
        )
        let screenshotsPath = screenshotDirectoryRelativePath(for: meetingID)
        let screenshotsDirectory = meetingDirectory.appendingPathComponent(
            Self.screenshotDirectoryName,
            isDirectory: true
        )
        _ = try identity(
            at: screenshotsDirectory,
            expectedFileType: mode_t(S_IFDIR),
            missingError: .screenshotNotFound,
            invalidError: .invalidRelativePath(screenshotsPath)
        )
        return screenshotsDirectory
    }

    private func ensureDirectory(
        at url: URL,
        invalidPath: String
    ) throws {
        if !fileSystemEntryExists(at: url) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
        }
        _ = try identity(
            at: url,
            expectedFileType: mode_t(S_IFDIR),
            missingError: .invalidRelativePath(invalidPath),
            invalidError: .invalidRelativePath(invalidPath)
        )
    }

    private func validatedScreenshotFileName(
        meetingID: UUID,
        relativePath: String
    ) throws -> String {
        let path = relativePath as NSString
        let components = path.pathComponents
        guard !relativePath.isEmpty,
              !path.isAbsolutePath,
              components.count == 3,
              components[0] == meetingID.uuidString,
              components[1] == Self.screenshotDirectoryName else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }
        let fileName = components[2]
        let filePath = fileName as NSString
        let reconstructed = screenshotRelativePath(
            meetingID: meetingID,
            fileName: fileName
        )
        guard reconstructed == relativePath,
              filePath.pathExtension.lowercased() == "png",
              UUID(uuidString: filePath.deletingPathExtension) != nil else {
            throw MeetingFileStoreError.invalidRelativePath(relativePath)
        }
        return fileName
    }

    private func validatedStagedScreenshotDeletion(
        _ deletion: StagedScreenshotDeletion
    ) throws -> (original: URL, staged: URL) {
        let originalFileName = try validatedScreenshotFileName(
            meetingID: deletion.meetingID,
            relativePath: deletion.originalRelativePath
        )
        let directory = try existingScreenshotDirectory(
            for: deletion.meetingID
        )
        let stagedPath = deletion.stagedRelativePath as NSString
        let stagedComponents = stagedPath.pathComponents
        guard !stagedPath.isAbsolutePath,
              stagedComponents.count == 3,
              stagedComponents[0] == deletion.meetingID.uuidString,
              stagedComponents[1] == Self.screenshotDirectoryName,
              stagedComponents[2].hasPrefix(".screenshot-delete-"),
              stagedComponents[2].hasSuffix(".tmp"),
              screenshotRelativePath(
                  meetingID: deletion.meetingID,
                  fileName: stagedComponents[2]
              ) == deletion.stagedRelativePath else {
            throw MeetingFileStoreError.invalidRelativePath(
                deletion.stagedRelativePath
            )
        }

        let originalURL = directory.appendingPathComponent(originalFileName)
        let stagedURL = directory.appendingPathComponent(stagedComponents[2])
        let currentIdentity = try identity(
            at: stagedURL,
            expectedFileType: mode_t(S_IFREG),
            missingError: .screenshotIdentityChanged,
            invalidError: .screenshotIdentityChanged
        )
        guard currentIdentity == deletion.fileIdentity else {
            throw MeetingFileStoreError.screenshotIdentityChanged
        }
        return (originalURL, stagedURL)
    }

    private func screenshotRelativePath(
        meetingID: UUID,
        fileName: String
    ) -> String {
        "\(screenshotDirectoryRelativePath(for: meetingID))/\(fileName)"
    }

    private func screenshotDirectoryRelativePath(for meetingID: UUID) -> String {
        "\(meetingID.uuidString)/\(Self.screenshotDirectoryName)"
    }

    private func fileSystemEntryExists(at url: URL) -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &information) == 0
        }
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
