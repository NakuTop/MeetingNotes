import Foundation

enum MicrophoneRuntimeStatus: String, Equatable, Sendable {
    case idle
    case permissionNotDetermined
    case permissionDenied
    case permissionRestricted
    case permissionAuthorized
    case avFoundationDeviceAvailable
    case avFoundationDeviceUnavailable
    case coreAudioDeviceAvailable
    case coreAudioDeviceUnavailable
    case captureConfigurationFailed
    case captureStartFailed
    case captureNoFrames
    case fallbackActive
    case deviceDisconnected
    case recovering
    case stopped
    case failed
}

enum MicrophoneCaptureErrorCategory: String, Equatable, Sendable {
    case permissionNotDetermined
    case permissionDenied
    case permissionRestricted
    case configurationFailed
    case startFailed
    case noFrames
    case deviceDisconnected
    case runtimeFailure
    case noUsableInputDevice
}

struct MicrophoneCaptureTelemetry: Equatable, Sendable {
    var appVersion: String = ""
    var buildNumber: String = ""
    var macOSVersion: String = ""
    var architecture: String = ""
    var microphonePermission: CapturePermissionStatus = .notDetermined
    var avFoundationInputCount = 0
    var coreAudioInputCount = 0
    var avFoundationDefaultAvailable = false
    var coreAudioDefaultAvailable = false
    var preferredDeviceAvailable = false
    var selectedInputBackend: MicrophoneCaptureBackend?
    var captureBackend: MicrophoneCaptureBackend?
    var captureStarted = false
    var receivedFrameCount = 0
    var sampleRate: Double = 0
    var channelCount = 0
    var automaticRecoveryAttemptCount = 0
    var lastCaptureErrorCategory: MicrophoneCaptureErrorCategory?
}

struct MicrophoneRuntimeSnapshot: Equatable, Sendable {
    var status: MicrophoneRuntimeStatus = .idle
    var telemetry = MicrophoneCaptureTelemetry()
}

protocol MicrophonePermissionChecking: Sendable {
    func status() -> CapturePermissionStatus
}

protocol MicrophoneRuntimeReporting: Sendable {
    func runtimeSnapshot() async -> MicrophoneRuntimeSnapshot
}
