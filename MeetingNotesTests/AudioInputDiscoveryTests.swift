import CoreAudio
import XCTest
@testable import MeetingNotes

final class AudioInputDiscoveryTests: XCTestCase {
    func testMergesAVFoundationAndCoreAudioIdentitiesByExactUID() throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "microphone-uid",
            name: "MacBook 麦克风",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(42),
            uid: "microphone-uid",
            name: "MacBook 麦克风",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: true
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [avf],
                coreAudioInputs: [coreAudio]
            )
        )

        let device = try XCTUnwrap(merged.first)
        XCTAssertEqual(device.id, "microphone-uid")
        XCTAssertEqual(device.stableID, "avf:microphone-uid")
        XCTAssertEqual(device.avFoundationUniqueID, "microphone-uid")
        XCTAssertEqual(device.coreAudioUID, "microphone-uid")
        XCTAssertEqual(device.coreAudioDeviceID, AudioDeviceID(42))
        XCTAssertTrue(device.isAVFoundationAvailable)
        XCTAssertTrue(device.isCoreAudioAvailable)
        XCTAssertTrue(device.isSystemDefault)
        XCTAssertTrue(device.isUsable)
    }

    func testSystemDefaultRelationshipMatchesAVFoundationCounterpart() throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "avf-default",
            name: "Built-in Microphone",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(7),
            uid: "ca-default-uid",
            name: "Built-in Microphone",
            isAlive: true,
            inputChannelCount: 2,
            isSystemDefault: true
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [avf],
                coreAudioInputs: [coreAudio]
            )
        )

        let device = try XCTUnwrap(merged.first)
        XCTAssertEqual(device.id, "avf-default")
        XCTAssertEqual(device.coreAudioUID, "ca-default-uid")
        XCTAssertEqual(device.coreAudioDeviceID, AudioDeviceID(7))
        XCTAssertTrue(device.isAVFoundationAvailable)
        XCTAssertTrue(device.isCoreAudioAvailable)
    }

    func testCoreAudioOnlyDeviceUsesNamespacedStableID() throws {
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(9),
            uid: "external-mic",
            name: "USB 麦克风",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: false
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [],
                coreAudioInputs: [coreAudio]
            )
        )

        let device = try XCTUnwrap(merged.first)
        XCTAssertEqual(device.id, "ca:external-mic")
        XCTAssertEqual(device.stableID, "ca:external-mic")
        XCTAssertFalse(device.isAVFoundationAvailable)
        XCTAssertTrue(device.isCoreAudioAvailable)
        XCTAssertTrue(device.isUsable)
    }

    func testAVFoundationDeviceWithoutCoreAudioCounterpartRemainsUsable() throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "avf-only",
            name: "AirPods",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [avf],
                coreAudioInputs: []
            )
        )

        let device = try XCTUnwrap(merged.first)
        XCTAssertTrue(device.isAVFoundationAvailable)
        XCTAssertFalse(device.isCoreAudioAvailable)
        XCTAssertTrue(device.isUsable)
    }

    func testResolverPrefersSavedDeviceOverSystemDefault() throws {
        let saved = makeInput(
            id: "saved-mic",
            name: "Saved Mic",
            isSystemDefault: false,
            avFoundationUniqueID: "saved-mic"
        )
        let builtIn = makeInput(
            id: "built-in",
            name: "Built In",
            isSystemDefault: true,
            avFoundationUniqueID: "built-in"
        )
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:saved-mic",
            legacyAVFoundationID: "saved-mic",
            coreAudioUID: nil
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: preferred,
                inputs: [builtIn, saved]
            )
        )

        XCTAssertEqual(resolution.plan, .avFoundation(deviceID: "saved-mic"))
        XCTAssertEqual(resolution.kind, .preferred)
    }

    func testResolverUsesAVFoundationSystemDefaultWhenNoPreference() throws {
        let first = makeInput(
            id: "first",
            name: "First",
            avFoundationUniqueID: "first"
        )
        let builtIn = makeInput(
            id: "built-in",
            name: "Built In",
            isSystemDefault: true,
            avFoundationUniqueID: "built-in"
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: .automatic,
                inputs: [first, builtIn]
            )
        )

        XCTAssertEqual(
            resolution.plan,
            .avFoundation(deviceID: "built-in")
        )
        XCTAssertEqual(resolution.kind, .systemDefault)
    }

    func testResolverUsesDiscoveryDeviceWhenDefaultIsNil() throws {
        let discovered = makeInput(
            id: "discovered",
            name: "Discovered",
            avFoundationUniqueID: "discovered"
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: .automatic,
                inputs: [discovered]
            )
        )

        XCTAssertEqual(
            resolution.plan,
            .avFoundation(deviceID: "discovered")
        )
        XCTAssertEqual(resolution.kind, .firstUsable)
    }

    func testResolverFallsBackToCoreAudioWhenAVFoundationHasNoDevices() throws {
        let builtIn = makeCoreAudioInput(
            deviceID: AudioDeviceID(42),
            uid: "built-in-mic",
            name: "MacBook 麦克风",
            isSystemDefault: true
        )
        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [],
                coreAudioInputs: [builtIn]
            )
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: .automatic,
                inputs: merged
            )
        )

        XCTAssertEqual(
            resolution.plan,
            .coreAudio(deviceID: AudioDeviceID(42), uid: "built-in-mic")
        )
        XCTAssertEqual(resolution.kind, .systemDefault)
        XCTAssertTrue(resolution.usesCoreAudioFallback)
    }

    func testAuthorizedMicrophoneFallsBackToCoreAudioWhenAVFoundationHasNoDevices() {
        // Regression for the reported compatibility bug:
        // permission = authorized, AVCaptureDevice.default = nil,
        // discovery = [], Core Audio inputs = [builtInMic], CA default exists.
        let permission = StaticMicrophonePermissionChecker(status: .authorized)
        let coreAudio = makeCoreAudioInput(
            deviceID: AudioDeviceID(42),
            uid: "built-in-mic",
            name: "MacBook 麦克风",
            isSystemDefault: true
        )
        let discovery = StaticAudioInputDiscoveryProvider(
            snapshot: AudioInputDiscoverySnapshot(
                avFoundationInputs: [],
                coreAudioInputs: [coreAudio]
            )
        )

        XCTAssertEqual(permission.status(), .authorized)
        let snapshot = try! discovery.discover()
        XCTAssertEqual(snapshot.avFoundationInputCount, 0)
        XCTAssertEqual(snapshot.coreAudioInputCount, 1)
        XCTAssertTrue(snapshot.coreAudioDefaultAvailable)
        XCTAssertFalse(snapshot.avFoundationDefaultAvailable)

        let resolution = AudioInputDeviceResolver.resolveCapture(
            preferred: .automatic,
            inputs: AudioInputDeviceIdentityMatcher.mergedInputs(from: snapshot)
        )
        XCTAssertEqual(
            resolution?.plan,
            .coreAudio(deviceID: AudioDeviceID(42), uid: "built-in-mic")
        )
    }

    func testMissingSavedDeviceFallsBackWithoutOverwritingPreference() throws {
        let builtIn = makeInput(
            id: "built-in",
            name: "Built In",
            isSystemDefault: true,
            avFoundationUniqueID: "built-in"
        )
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:missing",
            legacyAVFoundationID: "missing",
            coreAudioUID: nil
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: preferred,
                inputs: [builtIn]
            )
        )

        XCTAssertEqual(
            resolution.plan,
            .avFoundation(deviceID: "built-in")
        )
        XCTAssertEqual(
            resolution.kind,
            .fallback(unavailablePreferredID: "missing")
        )
    }

    func testNamespacedCoreAudioStableIDDoesNotMatchAVFoundationDevice() {
        let avf = makeInput(
            id: "shared-name",
            name: "Shared Name",
            avFoundationUniqueID: "shared-name"
        )
        let preferred = PreferredAudioInput(
            backend: .coreAudio,
            stableID: "ca:shared-name",
            legacyAVFoundationID: nil,
            coreAudioUID: nil
        )

        let resolution = AudioInputDeviceResolver.resolveCapture(
            preferred: preferred,
            inputs: [avf]
        )

        // The AVFoundation device must not be selected by a Core Audio
        // namespaced identifier, even though the bare identifier is equal.
        XCTAssertEqual(resolution?.plan, .avFoundation(deviceID: "shared-name"))
        XCTAssertEqual(
            resolution?.kind,
            .fallback(unavailablePreferredID: "ca:shared-name")
        )
    }

    private func makeInput(
        id: String,
        name: String,
        isConnected: Bool = true,
        isSuspended: Bool = false,
        isSystemDefault: Bool = false,
        avFoundationUniqueID: String? = nil,
        coreAudioUID: String? = nil,
        coreAudioDeviceID: AudioDeviceID? = nil,
        isAVFoundationAvailable: Bool = true,
        isCoreAudioAvailable: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name,
            manufacturer: "Test",
            isConnected: isConnected,
            isSuspended: isSuspended,
            isInUseByAnotherApplication: false,
            isSystemDefault: isSystemDefault,
            avFoundationUniqueID: avFoundationUniqueID ?? id,
            coreAudioUID: coreAudioUID,
            coreAudioDeviceID: coreAudioDeviceID,
            inputChannelCount: 1,
            isAVFoundationAvailable: isAVFoundationAvailable,
            isCoreAudioAvailable: isCoreAudioAvailable
        )
    }

    private func makeCoreAudioInput(
        deviceID: AudioDeviceID,
        uid: String,
        name: String,
        isAlive: Bool = true,
        isSystemDefault: Bool = false
    ) -> CoreAudioInputDevice {
        CoreAudioInputDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            isAlive: isAlive,
            inputChannelCount: 1,
            isSystemDefault: isSystemDefault
        )
    }
}

private struct StaticMicrophonePermissionChecker:
    MicrophonePermissionChecking {
    let statusValue: CapturePermissionStatus

    init(status: CapturePermissionStatus) {
        statusValue = status
    }

    func status() -> CapturePermissionStatus {
        statusValue
    }
}

private struct StaticAudioInputDiscoveryProvider:
    AudioInputDeviceProviding {
    let snapshotValue: AudioInputDiscoverySnapshot

    init(snapshot: AudioInputDiscoverySnapshot) {
        snapshotValue = snapshot
    }

    func discover() throws -> AudioInputDiscoverySnapshot {
        snapshotValue
    }
}
