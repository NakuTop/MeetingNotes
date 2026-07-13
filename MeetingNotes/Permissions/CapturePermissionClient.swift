import AVFoundation
import CoreGraphics
import Foundation

enum CapturePermission: Equatable, Hashable, Sendable {
    case microphone
    case screenRecording
}

enum CapturePermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .notDetermined:
            self = .notDetermined
        case .denied, .restricted:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}

protocol CapturePermissionSystem: Sendable {
    func status(
        for permission: CapturePermission
    ) async -> CapturePermissionStatus

    func requestAccess(
        for permission: CapturePermission
    ) async -> CapturePermissionStatus
}

struct CapturePermissionClient: Sendable {
    private let system: any CapturePermissionSystem

    init(system: any CapturePermissionSystem) {
        self.system = system
    }

    static func requiredPermissions(
        for mode: MeetingMode
    ) -> [CapturePermission] {
        switch mode {
        case .offline:
            return [.microphone]
        case .online:
            return [.microphone, .screenRecording]
        }
    }

    func statuses(
        for mode: MeetingMode
    ) async -> [CapturePermission: CapturePermissionStatus] {
        var result: [CapturePermission: CapturePermissionStatus] = [:]
        for permission in Self.requiredPermissions(for: mode) {
            result[permission] = await system.status(for: permission)
        }
        return result
    }

    func requestRequiredPermissions(
        for mode: MeetingMode
    ) async -> [CapturePermission: CapturePermissionStatus] {
        var result: [CapturePermission: CapturePermissionStatus] = [:]
        for permission in Self.requiredPermissions(for: mode) {
            let currentStatus = await system.status(for: permission)
            if currentStatus == .notDetermined {
                result[permission] = await system.requestAccess(for: permission)
            } else {
                result[permission] = currentStatus
            }
        }
        return result
    }
}

final class LiveCapturePermissionSystem: CapturePermissionSystem, @unchecked Sendable {
    private enum Key {
        static let requestedScreenRecording = "permissions.requestedScreenRecording"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func status(
        for permission: CapturePermission
    ) async -> CapturePermissionStatus {
        switch permission {
        case .microphone:
            return CapturePermissionStatus(
                AVCaptureDevice.authorizationStatus(for: .audio)
            )
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() {
                return .authorized
            }
            return defaults.bool(forKey: Key.requestedScreenRecording)
                ? .denied
                : .notDetermined
        }
    }

    func requestAccess(
        for permission: CapturePermission
    ) async -> CapturePermissionStatus {
        switch permission {
        case .microphone:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .authorized : .denied
        case .screenRecording:
            let granted = CGRequestScreenCaptureAccess()
            defaults.set(true, forKey: Key.requestedScreenRecording)
            return granted ? .authorized : .denied
        }
    }
}
