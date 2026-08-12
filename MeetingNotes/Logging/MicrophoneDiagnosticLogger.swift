import Foundation
import OSLog

enum MicrophoneDiagnosticLogger {
    private static let discovery = Logger(
        subsystem: "com.shenminghao.MeetingNotes",
        category: "AudioDeviceDiscovery"
    )
    private static let capture = Logger(
        subsystem: "com.shenminghao.MeetingNotes",
        category: "MicrophoneCapture"
    )
    private static let recovery = Logger(
        subsystem: "com.shenminghao.MeetingNotes",
        category: "MicrophoneRecovery"
    )
    private static let fallback = Logger(
        subsystem: "com.shenminghao.MeetingNotes",
        category: "CoreAudioFallback"
    )

    static func discovery(
        permission: CapturePermissionStatus,
        avFoundationInputCount: Int,
        coreAudioInputCount: Int,
        avFoundationDefaultAvailable: Bool,
        coreAudioDefaultAvailable: Bool
    ) {
        discovery.info(
            """
            [AudioDeviceDiscovery] permission=\(permissionDescription(permission), privacy: .public) \
            avf_count=\(avFoundationInputCount, privacy: .public) \
            ca_count=\(coreAudioInputCount, privacy: .public) \
            avf_default=\(avFoundationDefaultAvailable, privacy: .public) \
            ca_default=\(coreAudioDefaultAvailable, privacy: .public)
            """
        )
    }

    static func avFoundationCaptureUnavailable() {
        capture.warning(
            "[MicrophoneCapture] AVFoundation capture unavailable; switching to Core Audio fallback"
        )
    }

    static func fallbackStarted() {
        fallback.info("[CoreAudioFallback] Core Audio fallback started")
    }

    static func firstFrameReceived() {
        capture.info("[MicrophoneCapture] First microphone frame received")
    }

    static func recoveryStarted(attempt: Int) {
        recovery.info(
            "[MicrophoneRecovery] recovering attempt=\(attempt, privacy: .public)"
        )
    }

    static func captureFailure(category: MicrophoneCaptureErrorCategory?) {
        capture.warning(
            "[MicrophoneCapture] capture failure category=\(category?.rawValue ?? "unknown", privacy: .public)"
        )
    }

    private static func permissionDescription(
        _ permission: CapturePermissionStatus
    ) -> String {
        switch permission {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        case .unavailable: "unavailable"
        }
    }
}
