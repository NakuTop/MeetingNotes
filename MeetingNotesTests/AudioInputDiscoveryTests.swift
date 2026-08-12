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

    func testAmbiguousDuplicateNamesAreNotMergedByEnumerationOrder()
        throws {
        let avfA = AVFoundationInputDevice(
            uniqueID: "avf-a",
            name: "USB Mic",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: false
        )
        let avfB = AVFoundationInputDevice(
            uniqueID: "avf-b",
            name: "USB Mic",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: false
        )
        let caA = CoreAudioInputDevice(
            deviceID: AudioDeviceID(10),
            uid: "ca-a",
            name: "USB Mic",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: false
        )
        let caB = CoreAudioInputDevice(
            deviceID: AudioDeviceID(20),
            uid: "ca-b",
            name: "USB Mic",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: false
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [avfA, avfB],
                coreAudioInputs: [caB, caA]
            )
        )

        XCTAssertEqual(merged.count, 4)
        XCTAssertTrue(
            merged.filter {
                $0.isAVFoundationAvailable
                    && $0.isCoreAudioAvailable
            }.isEmpty
        )
        XCTAssertTrue(merged.contains { $0.id == "avf-a" })
        XCTAssertTrue(merged.contains { $0.id == "avf-b" })
        XCTAssertTrue(merged.contains { $0.id == "ca:ca-a" })
        XCTAssertTrue(merged.contains { $0.id == "ca:ca-b" })
    }

    func testUniqueNameFallbackStillMergesSingleUnambiguousPair()
        throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "avf-unique",
            name: "Solo Mic",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: false
        )
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(30),
            uid: "ca-unique",
            name: "Solo Mic",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: false
        )

        let merged = AudioInputDeviceIdentityMatcher.mergedInputs(
            from: AudioInputDiscoverySnapshot(
                avFoundationInputs: [avf],
                coreAudioInputs: [coreAudio]
            )
        )

        let device = try XCTUnwrap(merged.first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(device.isAVFoundationAvailable)
        XCTAssertTrue(device.isCoreAudioAvailable)
        XCTAssertEqual(device.avFoundationUniqueID, "avf-unique")
        XCTAssertEqual(device.coreAudioUID, "ca-unique")
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

    func testResolverAllowsCoreAudioBackendAfterAVFoundationFailureOnSamePhysicalDevice() throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "same-id",
            name: "Same Microphone",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(42),
            uid: "same-id",
            name: "Same Microphone",
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

        let firstResolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: .automatic,
                inputs: merged
            )
        )
        XCTAssertEqual(
            firstResolution.plan,
            .avFoundation(deviceID: "same-id")
        )

        let failedAVF = MicrophoneCaptureAttemptKey(
            physicalStableID: firstResolution.device.stableID,
            backend: .avFoundation
        )
        let secondResolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: .automatic,
                inputs: merged,
                excludingAttempts: [failedAVF]
            )
        )

        XCTAssertEqual(
            secondResolution.plan,
            .coreAudio(deviceID: AudioDeviceID(42), uid: "same-id")
        )
    }

    func testResolverHonorsExplicitCoreAudioBackendPreference() throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "same-id",
            name: "Same Microphone",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )
        let coreAudio = CoreAudioInputDevice(
            deviceID: AudioDeviceID(42),
            uid: "same-id",
            name: "Same Microphone",
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
        let preferred = PreferredAudioInput(
            backend: .coreAudio,
            stableID: device.stableID,
            legacyAVFoundationID: "same-id",
            coreAudioUID: "same-id"
        )

        let resolution = try XCTUnwrap(
            AudioInputDeviceResolver.resolveCapture(
                preferred: preferred,
                inputs: merged
            )
        )

        XCTAssertEqual(
            resolution.plan,
            .coreAudio(deviceID: AudioDeviceID(42), uid: "same-id")
        )
    }

    func testDiscoveryPreservesCoreAudioWhenAVFoundationThrows()
        throws {
        let builtIn = CoreAudioInputDevice(
            deviceID: AudioDeviceID(42),
            uid: "built-in-mic",
            name: "Built-in",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: true
        )
        let provider = LiveAudioInputDeviceProvider(
            avFoundationProvider:
                ThrowingAVFoundationInputDeviceProvider(),
            coreAudioProvider:
                StaticCoreAudioInputDeviceProvider(
                    inputsValue: [builtIn]
                )
        )

        let snapshot = try provider.discover()

        XCTAssertTrue(snapshot.avFoundationInputs.isEmpty)
        XCTAssertEqual(snapshot.coreAudioInputs.count, 1)
        XCTAssertEqual(snapshot.failedBackends, [.avFoundation])
        XCTAssertTrue(snapshot.avFoundationDiscoveryFailed)
        XCTAssertFalse(snapshot.coreAudioDiscoveryFailed)
    }

    func testDiscoveryPreservesAVFoundationWhenCoreAudioThrows()
        throws {
        let avf = AVFoundationInputDevice(
            uniqueID: "built-in-avf",
            name: "Built-in",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true
        )
        let provider = LiveAudioInputDeviceProvider(
            avFoundationProvider:
                StaticAVFoundationInputDeviceProvider(
                    inputsValue: [avf]
                ),
            coreAudioProvider:
                ThrowingCoreAudioInputDeviceProvider()
        )

        let snapshot = try provider.discover()

        XCTAssertTrue(snapshot.coreAudioInputs.isEmpty)
        XCTAssertEqual(snapshot.avFoundationInputs.count, 1)
        XCTAssertEqual(snapshot.failedBackends, [.coreAudio])
        XCTAssertFalse(snapshot.avFoundationDiscoveryFailed)
        XCTAssertTrue(snapshot.coreAudioDiscoveryFailed)
    }

    func testDiscoveryThrowsOnlyWhenBothBackendsFail() {
        let provider = LiveAudioInputDeviceProvider(
            avFoundationProvider:
                ThrowingAVFoundationInputDeviceProvider(),
            coreAudioProvider:
                ThrowingCoreAudioInputDeviceProvider()
        )

        XCTAssertThrowsError(try provider.discover()) { error in
            XCTAssertEqual(
                error as? AudioInputDiscoveryError,
                .allBackendsFailed
            )
        }
    }

    func testSuccessfulEmptyDiscoveryIsNotReportedAsBackendFailure()
        throws {
        let provider = LiveAudioInputDeviceProvider(
            avFoundationProvider:
                StaticAVFoundationInputDeviceProvider(
                    inputsValue: []
                ),
            coreAudioProvider:
                StaticCoreAudioInputDeviceProvider(
                    inputsValue: []
                )
        )

        let snapshot = try provider.discover()

        XCTAssertTrue(snapshot.avFoundationInputs.isEmpty)
        XCTAssertTrue(snapshot.coreAudioInputs.isEmpty)
        XCTAssertTrue(snapshot.failedBackends.isEmpty)
        XCTAssertFalse(snapshot.avFoundationDiscoveryFailed)
        XCTAssertFalse(snapshot.coreAudioDiscoveryFailed)
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

private enum DiscoveryTestError: Error, Equatable, Sendable {
    case backendFailed
}

private struct ThrowingAVFoundationInputDeviceProvider:
    AVFoundationInputDeviceProviding {
    func inputs() throws -> [AVFoundationInputDevice] {
        throw DiscoveryTestError.backendFailed
    }
}

private struct ThrowingCoreAudioInputDeviceProvider:
    CoreAudioInputDeviceProviding {
    func inputs() throws -> [CoreAudioInputDevice] {
        throw DiscoveryTestError.backendFailed
    }
}

private struct StaticAVFoundationInputDeviceProvider:
    AVFoundationInputDeviceProviding {
    let inputsValue: [AVFoundationInputDevice]

    func inputs() throws -> [AVFoundationInputDevice] {
        inputsValue
    }
}

private struct StaticCoreAudioInputDeviceProvider:
    CoreAudioInputDeviceProviding {
    let inputsValue: [CoreAudioInputDevice]

    func inputs() throws -> [CoreAudioInputDevice] {
        inputsValue
    }
}
