import AVFoundation
import ScreenCaptureKit
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

    func testLiveScreenPermissionRemainsRetryableAfterDeniedRequest() async {
        let calls = PermissionInvocationRecorder()
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: {
                calls.recordScreenPreflight()
                return false
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            },
            screenProbe: {
                calls.recordScreenProbe()
                return .denied
            }
        )

        let firstStatus = await system.status(for: .screenRecording)
        let firstRequest = await system.requestAccess(for: .screenRecording)
        let secondStatus = await system.status(for: .screenRecording)
        let secondRequest = await system.requestAccess(for: .screenRecording)

        XCTAssertEqual(firstStatus, .notDetermined)
        XCTAssertEqual(firstRequest, .denied)
        XCTAssertEqual(secondStatus, .notDetermined)
        XCTAssertEqual(secondRequest, .denied)
        XCTAssertEqual(calls.screenPreflightCount, 4)
        XCTAssertEqual(calls.screenRequestCount, 2)
        XCTAssertEqual(calls.screenProbeCount, 6)
    }

    func testLiveScreenRequestTrustsFreshPreflightAfterRequestReturnsFalse() async {
        let calls = PermissionInvocationRecorder()
        let preflight = SequencedBool(values: [false, true])
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: {
                calls.recordScreenPreflight()
                return preflight.next()
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            },
            screenProbe: {
                calls.recordScreenProbe()
                return .denied
            }
        )

        let initialStatus = await system.status(for: .screenRecording)
        let requestStatus = await system.requestAccess(for: .screenRecording)

        XCTAssertEqual(initialStatus, .notDetermined)
        XCTAssertEqual(requestStatus, .authorized)
        XCTAssertEqual(calls.screenPreflightCount, 2)
        XCTAssertEqual(calls.screenRequestCount, 1)
        XCTAssertEqual(calls.screenProbeCount, 2)
    }

    func testLiveScreenRequestAcceptsScreenCaptureKitProbeWhenCGStateIsStale() async {
        let calls = PermissionInvocationRecorder()
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: {
                calls.recordScreenPreflight()
                return false
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            },
            screenProbe: {
                calls.recordScreenProbe()
                return .authorized
            }
        )

        let status = await system.requestAccess(for: .screenRecording)

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(calls.screenPreflightCount, 0)
        XCTAssertEqual(calls.screenRequestCount, 0)
        XCTAssertEqual(calls.screenProbeCount, 1)
    }

    func testScreenRequestAcceptsSuccessfulProbeAfterRequestReturnsFalse() async {
        let calls = PermissionInvocationRecorder()
        let probes = SequencedProbe(values: [.denied, .authorized])
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: {
                calls.recordScreenPreflight()
                return false
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            },
            screenProbe: {
                calls.recordScreenProbe()
                return probes.next()
            }
        )

        let status = await system.requestAccess(for: .screenRecording)

        XCTAssertEqual(status, .authorized)
        XCTAssertEqual(calls.screenProbeCount, 2)
        XCTAssertEqual(calls.screenRequestCount, 1)
    }

    func testNonPermissionProbeFailureDoesNotBecomePermissionDenial() async {
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: { false },
            screenRequest: { false },
            screenProbe: { .unavailable }
        )

        let status = await system.requestAccess(for: .screenRecording)
        XCTAssertEqual(status, .authorized)
    }

    func testClassifiesOnlyScreenCaptureUserDeclinedAsDenied() {
        let denied = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )
        let internalFailure = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.internalError.rawValue
        )

        XCTAssertEqual(ScreenCaptureProbeResult(error: denied), .denied)
        XCTAssertEqual(ScreenCaptureProbeResult(error: internalFailure), .unavailable)
        XCTAssertEqual(
            ScreenCaptureProbeResult(error: NSError(domain: NSCocoaErrorDomain, code: 1)),
            .unavailable
        )
    }

    func testEveryOnlineRetryRequestsScreenPermissionAgain() async {
        let calls = PermissionInvocationRecorder()
        let system = LiveCapturePermissionSystem(
            microphoneStatus: { .authorized },
            microphoneRequest: { true },
            screenPreflight: {
                calls.recordScreenPreflight()
                return false
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            },
            screenProbe: {
                calls.recordScreenProbe()
                return .denied
            }
        )
        let client = CapturePermissionClient(system: system)

        _ = await client.requestRequiredPermissions(for: .online)
        _ = await client.requestRequiredPermissions(for: .online)

        XCTAssertEqual(calls.screenPreflightCount, 2)
        XCTAssertEqual(calls.screenRequestCount, 2)
        XCTAssertEqual(calls.screenProbeCount, 4)
    }

    func testLiveOfflineRequestNeverTouchesScreenPermission() async {
        let calls = PermissionInvocationRecorder()
        let system = LiveCapturePermissionSystem(
            microphoneStatus: {
                calls.recordMicrophoneStatus()
                return .notDetermined
            },
            microphoneRequest: {
                calls.recordMicrophoneRequest()
                return true
            },
            screenPreflight: {
                calls.recordScreenPreflight()
                return false
            },
            screenRequest: {
                calls.recordScreenRequest()
                return false
            }
        )
        let client = CapturePermissionClient(system: system)

        let statuses = await client.requestRequiredPermissions(for: .offline)

        XCTAssertEqual(statuses, [.microphone: .authorized])
        XCTAssertEqual(calls.microphoneStatusCount, 1)
        XCTAssertEqual(calls.microphoneRequestCount, 1)
        XCTAssertEqual(calls.screenPreflightCount, 0)
        XCTAssertEqual(calls.screenRequestCount, 0)
    }
}

private final class SequencedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScreenCaptureProbeResult]

    init(values: [ScreenCaptureProbeResult]) {
        self.values = values
    }

    func next() -> ScreenCaptureProbeResult {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? .denied : values.removeFirst()
    }
}

private final class PermissionInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneStatuses = 0
    private var microphoneRequests = 0
    private var screenPreflights = 0
    private var screenRequests = 0
    private var screenProbes = 0

    var microphoneStatusCount: Int { withLock { microphoneStatuses } }
    var microphoneRequestCount: Int { withLock { microphoneRequests } }
    var screenPreflightCount: Int { withLock { screenPreflights } }
    var screenRequestCount: Int { withLock { screenRequests } }
    var screenProbeCount: Int { withLock { screenProbes } }

    func recordMicrophoneStatus() {
        withLock { microphoneStatuses += 1 }
    }

    func recordMicrophoneRequest() {
        withLock { microphoneRequests += 1 }
    }

    func recordScreenPreflight() {
        withLock { screenPreflights += 1 }
    }

    func recordScreenRequest() {
        withLock { screenRequests += 1 }
    }

    func recordScreenProbe() {
        withLock { screenProbes += 1 }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class SequencedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? false : values.removeFirst()
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
