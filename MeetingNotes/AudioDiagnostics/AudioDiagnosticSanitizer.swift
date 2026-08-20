import Foundation

enum AudioDiagnosticDeviceStatus: String, Codable, Sendable, Equatable {
    case automatic
    case selected
    case fallback
    case unavailable
    case disconnected
    case suspended
    case busy
}

enum AudioDiagnosticAPIErrorCategory: String, Codable, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case server
    case timeout
    case transport
    case invalidResponse
    case captureUnavailable
    case deviceQueryFailed
}

struct AudioDiagnosticDeviceMetadata: Sendable, Equatable {
    let name: String?
    let status: AudioDiagnosticDeviceStatus
    let isConnected: Bool
    let isSystemDefault: Bool
    let isInUseByAnotherApplication: Bool

    init(
        name: String?,
        status: AudioDiagnosticDeviceStatus,
        isConnected: Bool = false,
        isSystemDefault: Bool = false,
        isInUseByAnotherApplication: Bool = false
    ) {
        self.name = name
        self.status = status
        self.isConnected = isConnected
        self.isSystemDefault = isSystemDefault
        self.isInUseByAnotherApplication = isInUseByAnotherApplication
    }
}

struct AudioDiagnosticUploadMetadata: Sendable, Equatable {
    let appVersion: String
    let hardwareModel: String
    let macOSVersion: String
    let inputDevice: AudioDiagnosticDeviceMetadata
    let outputDevice: AudioDiagnosticDeviceMetadata
    let apiErrorCategory: AudioDiagnosticAPIErrorCategory?
}

struct AudioDiagnosticUploadDevice: Codable, Sendable, Equatable {
    let name: String
    let status: AudioDiagnosticDeviceStatus
    let isConnected: Bool
    let isSystemDefault: Bool
    let isInUseByAnotherApplication: Bool
}

struct AudioDiagnosticUploadMetrics: Codable, Sendable, Equatable {
    let frameCount: Int
    let level: AudioLevelBand
    let sampleRate: Double
    let channelCount: Int
    let observationMilliseconds: Int
}

struct AudioDiagnosticUploadEnvelope: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let hardwareModel: String
    let macOSVersion: String
    let microphonePermission: AudioDiagnosticPermissionStatus
    let screenPermission: AudioDiagnosticPermissionStatus?
    let inputDevice: AudioDiagnosticUploadDevice
    let outputDevice: AudioDiagnosticUploadDevice
    let inputDeviceAvailable: Bool
    let outputToneWasScheduled: Bool
    let userHeardOutputTone: Bool?
    let microphoneMetrics: AudioDiagnosticUploadMetrics?
    let systemAudioMetrics: AudioDiagnosticUploadMetrics?
    let historicalPlaybackFailed: Bool
    let microphoneTestOutcome: AudioDiagnosticStageOutcome
    let systemAudioTestOutcome: AudioDiagnosticStageOutcome
    let diagnosticFailureStage: AudioDiagnosticStage?
    let primaryIssueCode: AudioDiagnosticIssueCode
    let supportingIssueCodes: [AudioDiagnosticIssueCode]
    let localIssue: String
    let localSolution: String
    let apiErrorCategory: AudioDiagnosticAPIErrorCategory?
}

struct AudioDiagnosticSanitizer: Sendable {
    private static let maximumMetadataLength = 80
    private static let maximumObservationMilliseconds = 60_000.0
    private static let unknownDeviceName = "未知设备"

    func makeEnvelope(
        report: AudioDiagnosticReport,
        metadata: AudioDiagnosticUploadMetadata
    ) -> AudioDiagnosticUploadEnvelope {
        AudioDiagnosticUploadEnvelope(
            schemaVersion: 2,
            appVersion: sanitize(
                metadata.appVersion,
                fallback: "unknown"
            ),
            hardwareModel: sanitize(
                metadata.hardwareModel,
                fallback: "unknown"
            ),
            macOSVersion: sanitize(
                metadata.macOSVersion,
                fallback: "unknown"
            ),
            microphonePermission: report.facts.microphonePermission,
            screenPermission: report.facts.screenPermission,
            inputDevice: uploadDevice(metadata.inputDevice),
            outputDevice: uploadDevice(metadata.outputDevice),
            inputDeviceAvailable: report.facts.inputDeviceAvailable,
            outputToneWasScheduled: report.facts.outputToneWasScheduled,
            userHeardOutputTone: report.facts.userHeardOutputTone,
            microphoneMetrics: uploadMetrics(report.facts.microphoneMetrics),
            systemAudioMetrics: uploadMetrics(report.facts.systemAudioMetrics),
            historicalPlaybackFailed: report.facts.historicalPlaybackFailed,
            microphoneTestOutcome: report.facts.microphoneTestOutcome,
            systemAudioTestOutcome: report.facts.systemAudioTestOutcome,
            diagnosticFailureStage: failureStage(
                for: report.primaryIssue
            ),
            primaryIssueCode: report.primaryIssue,
            supportingIssueCodes: report.supportingIssues,
            localIssue: report.localIssue,
            localSolution: report.localSolution,
            apiErrorCategory: metadata.apiErrorCategory
        )
    }

    private func failureStage(
        for issue: AudioDiagnosticIssueCode
    ) -> AudioDiagnosticStage? {
        switch issue {
        case .microphoneDiagnosticTimedOut, .microphoneDiagnosticFailed:
            return .microphone
        case .systemAudioDiagnosticTimedOut, .systemAudioDiagnosticFailed:
            return .systemAudio
        default:
            return nil
        }
    }

    private func uploadDevice(
        _ metadata: AudioDiagnosticDeviceMetadata
    ) -> AudioDiagnosticUploadDevice {
        AudioDiagnosticUploadDevice(
            name: sanitize(
                metadata.name ?? "",
                fallback: Self.unknownDeviceName
            ),
            status: metadata.status,
            isConnected: metadata.isConnected,
            isSystemDefault: metadata.isSystemDefault,
            isInUseByAnotherApplication:
                metadata.isInUseByAnotherApplication
        )
    }

    private func uploadMetrics(
        _ metrics: AudioSignalMetrics?
    ) -> AudioDiagnosticUploadMetrics? {
        guard let metrics else { return nil }
        let milliseconds = metrics.observationDuration.isFinite
            ? Int(
                min(
                    max(0, metrics.observationDuration * 1_000),
                    Self.maximumObservationMilliseconds
                ).rounded()
            )
            : 0
        let channelCount = max(0, metrics.channelCount)
        let frameCount = channelCount > 0
            ? max(0, metrics.sampleCount) / channelCount
            : 0
        return AudioDiagnosticUploadMetrics(
            frameCount: frameCount,
            level: metrics.level,
            sampleRate: metrics.sampleRate.isFinite
                ? max(0, metrics.sampleRate)
                : 0,
            channelCount: channelCount,
            observationMilliseconds: milliseconds
        )
    }

    private func sanitize(_ value: String, fallback: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(min(value.count, Self.maximumMetadataLength))

        for scalar in value.unicodeScalars {
            if CharacterSet.illegalCharacters.contains(scalar) {
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                normalized.append(" ")
            } else {
                normalized.unicodeScalars.append(scalar)
            }
        }

        let collapsed = normalized
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let bounded = String(collapsed.prefix(Self.maximumMetadataLength))
        return bounded.isEmpty ? fallback : bounded
    }
}
