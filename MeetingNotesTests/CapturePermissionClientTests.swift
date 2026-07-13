import AVFoundation
import XCTest
@testable import MeetingNotes

final class CapturePermissionClientTests: XCTestCase {
    func testMapsSystemMicrophoneAuthorizationStatuses() {
        XCTAssertEqual(CapturePermissionStatus(.authorized), .authorized)
        XCTAssertEqual(CapturePermissionStatus(.denied), .denied)
        XCTAssertEqual(CapturePermissionStatus(.restricted), .denied)
        XCTAssertEqual(CapturePermissionStatus(.notDetermined), .notDetermined)
    }

    func testOfflineRequestsOnlyMicrophoneWhileOnlineRequiresBoth() async {
        let offlineSystem = RecordingPermissionSystem()
        let offlineClient = CapturePermissionClient(system: offlineSystem)

        _ = await offlineClient.requestRequiredPermissions(for: .offline)

        let offlineRequests = await offlineSystem.requestedPermissions()
        XCTAssertEqual(offlineRequests, [.microphone])

        let onlineSystem = RecordingPermissionSystem()
        let onlineClient = CapturePermissionClient(system: onlineSystem)

        _ = await onlineClient.requestRequiredPermissions(for: .online)

        let onlineRequests = await onlineSystem.requestedPermissions()
        XCTAssertEqual(onlineRequests, [.microphone, .screenRecording])
        XCTAssertEqual(
            CapturePermissionClient.requiredPermissions(for: .offline),
            [.microphone]
        )
        XCTAssertEqual(
            CapturePermissionClient.requiredPermissions(for: .online),
            [.microphone, .screenRecording]
        )
    }
}

private actor RecordingPermissionSystem: CapturePermissionSystem {
    private var requests: [CapturePermission] = []

    func status(for permission: CapturePermission) async -> CapturePermissionStatus {
        _ = permission
        return .notDetermined
    }

    func requestAccess(
        for permission: CapturePermission
    ) async -> CapturePermissionStatus {
        requests.append(permission)
        return .authorized
    }

    func requestedPermissions() -> [CapturePermission] {
        requests
    }
}
