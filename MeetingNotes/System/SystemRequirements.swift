import Foundation

struct SystemRequirementsSnapshot: Equatable, Sendable {
    let architecture: String
    let systemMajorVersion: Int
    let systemMinorVersion: Int
    let availableDiskBytes: Int64?
    let isSupportedPlatform: Bool
    let hasEnoughDiskSpace: Bool

    var canStartRecording: Bool {
        isSupportedPlatform && hasEnoughDiskSpace
    }
}

protocol SystemRequirementChecking: Sendable {
    func snapshot(for storageURL: URL) -> SystemRequirementsSnapshot
}

struct SystemRequirements: SystemRequirementChecking, Sendable {
    static let minimumSystemMajorVersion = 15
    static let minimumFreeDiskBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    func snapshot(for storageURL: URL) -> SystemRequirementsSnapshot {
        let probeURL = nearestExistingAncestor(of: storageURL)
        let values = try? probeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let availableBytes: Int64? = values?
            .volumeAvailableCapacityForImportantUsage
        return Self.evaluate(
            architecture: Self.currentArchitecture,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            availableDiskBytes: availableBytes
        )
    }

    static func evaluate(
        architecture: String,
        systemVersion: OperatingSystemVersion,
        availableDiskBytes: Int64?
    ) -> SystemRequirementsSnapshot {
        let supportedPlatform = architecture == "arm64"
            && systemVersion.majorVersion >= minimumSystemMajorVersion
        let enoughDisk = availableDiskBytes.map {
            $0 >= minimumFreeDiskBytes
        } ?? false
        return SystemRequirementsSnapshot(
            architecture: architecture,
            systemMajorVersion: systemVersion.majorVersion,
            systemMinorVersion: systemVersion.minorVersion,
            availableDiskBytes: availableDiskBytes,
            isSupportedPlatform: supportedPlatform,
            hasEnoughDiskSpace: enoughDisk
        )
    }

    static func settingsURL(for permission: CapturePermission) -> URL? {
        let anchor = switch permission {
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path),
              candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}
