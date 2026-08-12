import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class AdaptiveMicrophoneSampleProviderTests: XCTestCase {
    func testAVFoundationPrimaryPathIsUsedWhenAvailable() async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault(
                    includeCoreAudioFallback: true
                )
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(coreAudioStarts, 0)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.telemetry.captureBackend, .avFoundation)
        await provider.stop()
    }

    func testAuthorizedMicrophoneFallsBackToCoreAudioWhenAVFoundationHasNoDevices()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudioInput = CoreAudioInputDevice(
            deviceID: AudioDeviceID(42),
            uid: "built-in-mic",
            name: "MacBook 麦克风",
            isAlive: true,
            inputChannelCount: 1,
            isSystemDefault: true
        )
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: AudioInputDiscoverySnapshot(
                    avFoundationInputs: [],
                    coreAudioInputs: [coreAudioInput]
                )
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 0)
        XCTAssertEqual(coreAudioStarts, 1)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.telemetry.captureBackend, .coreAudioFallback)
        XCTAssertEqual(runtime.telemetry.avFoundationInputCount, 0)
        XCTAssertEqual(runtime.telemetry.coreAudioInputCount, 1)
        await provider.stop()
    }

    func testPermissionDeniedDoesNotFallback() async {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault()
            ),
            permission: StaticMicrophonePermissionChecker(status: .denied)
        )

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .permissionDenied
            )
        }

        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 0)
        XCTAssertEqual(coreAudioStarts, 0)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.status, .permissionDenied)
    }

    func testPermissionRestrictedDoesNotFallback() async {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault()
            ),
            permission: StaticMicrophonePermissionChecker(status: .restricted)
        )

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected restricted failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .permissionRestricted
            )
        }
        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 0)
        XCTAssertEqual(coreAudioStarts, 0)
    }

    func testAVFoundationStartFailureFallsBackToCoreAudio() async throws {
        let avf = FakeMicrophoneBackendProvider(
            mode: .startFails,
            startError: MicrophoneCaptureError.unableToStartSession
        )
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault(
                    includeCoreAudioFallback: true
                )
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(coreAudioStarts, 1)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.telemetry.captureBackend, .coreAudioFallback)
        await provider.stop()
    }

    func testAVFoundationFailureStillAllowsCoreAudioFallbackWhenUIDsAreIdentical()
        async throws {
        let avf = FakeMicrophoneBackendProvider(
            mode: .startFails,
            startError: MicrophoneCaptureError.unableToStartSession
        )
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let snapshot = AudioInputDiscoverySnapshot(
            avFoundationInputs: [
                AVFoundationInputDevice(
                    uniqueID: "same-id",
                    name: "Same Microphone",
                    manufacturer: "Apple",
                    isConnected: true,
                    isSuspended: false,
                    isInUseByAnotherApplication: false,
                    isSystemDefault: true
                )
            ],
            coreAudioInputs: [
                CoreAudioInputDevice(
                    deviceID: AudioDeviceID(42),
                    uid: "same-id",
                    name: "Same Microphone",
                    isAlive: true,
                    inputChannelCount: 1,
                    isSystemDefault: true
                )
            ]
        )
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshot
            ),
            configuration: MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(40),
                maxAutomaticRecoveryAttempts: 2
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let avfStarts = await avf.startCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(coreAudioStarts, 1)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.telemetry.captureBackend, .coreAudioFallback)
        await provider.stop()
    }

    func testNoFramesWatchdogSwitchesToCoreAudioFallback() async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .neverYields)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault(
                    includeCoreAudioFallback: true
                )
            ),
            configuration: MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(30),
                maxAutomaticRecoveryAttempts: 2
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let avfStarts = await avf.startCount()
        let avfStops = await avf.stopCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(avfStops, 1)
        XCTAssertEqual(coreAudioStarts, 1)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.telemetry.captureBackend, .coreAudioFallback)
        XCTAssertEqual(runtime.telemetry.automaticRecoveryAttemptCount, 1)
        await provider.stop()
    }

    func testDeviceDisconnectRediscoveryRestartsWithAlternativeDevice()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .failsAfterStart)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let firstSnapshot = snapshotWithAVFoundationDefault(
            uniqueID: "device-a"
        )
        let secondSnapshot = snapshotWithAVFoundationDefault(
            uniqueID: "device-b",
            includeCoreAudioFallback: true
        )
        let discovery = SequencedAudioInputDiscoveryProvider(
            snapshots: [firstSnapshot, secondSnapshot]
        )
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            configuration: MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(60),
                maxAutomaticRecoveryAttempts: 2
            )
        )

        let sample = try await firstSample(from: provider)

        XCTAssertNotNil(sample)
        let startedIDs = await avf.startedDeviceIDs()
        XCTAssertEqual(startedIDs, ["device-a", "device-b"])
        await provider.stop()
    }

    func testMultipleRecoveryAttemptsNeverRunTwoProvidersAtOnce()
        async throws {
        let avf = FakeMicrophoneBackendProvider(
            mode: .startFails,
            startError: MicrophoneCaptureError.unableToStartSession
        )
        let coreAudio = FakeMicrophoneBackendProvider(
            mode: .startFails,
            startError: MicrophoneCaptureError.unableToStartSession
        )
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault(
                    includeCoreAudioFallback: true
                )
            ),
            configuration: MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(20),
                maxAutomaticRecoveryAttempts: 2
            )
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected capture failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .unableToStartSession
            )
        }

        let avfEvents = await avf.eventSequence()
        let coreAudioEvents = await coreAudio.eventSequence()
        XCTAssertFalse(hasOverlappingActiveProviders(avfEvents))
        XCTAssertFalse(hasOverlappingActiveProviders(coreAudioEvents))
        XCTAssertTrue(avfEvents.contains(where: { $0.kind == .start }))
        XCTAssertTrue(coreAudioEvents.contains(where: { $0.kind == .start }))
        await provider.stop()
    }

    func testStopCancelsAndReleasesBackends() async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: StaticAudioInputDiscoveryProvider(
                snapshot: snapshotWithAVFoundationDefault()
            )
        )
        _ = try await provider.start(deviceID: nil)
        await avf.waitUntilStarted()

        await provider.stop()
        await provider.stop()

        let avfStops = await avf.stopCount()
        XCTAssertEqual(avfStops, 1)
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(runtime.status, .stopped)
    }

    func testExplicitPreferredMicrophoneIgnoresUnrelatedDefaultInputChange()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A"]
            )
        )
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:A",
            legacyAVFoundationID: "A",
            coreAudioUID: nil
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            preferredInputProvider: { preferred },
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        discovery.set(
            snapshotWithAVFDevices(
                defaultID: "B",
                ids: ["A", "B"]
            )
        )
        observer.emit(.defaultInputChanged)
        try await Task.sleep(for: .milliseconds(80))

        let avfStarts = await avf.startCount()
        let avfStartedIDs = await avf.startedDeviceIDs()
        let avfStops = await avf.stopCount()
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(avfStartedIDs, ["A"])
        XCTAssertEqual(avfStops, 0)
        XCTAssertEqual(coreAudioStarts, 0)
        await provider.stop()
    }

    func testAutomaticPreferenceSwitchesWhenSystemDefaultChanges()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A"]
            )
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        discovery.set(
            snapshotWithAVFDevices(
                defaultID: "B",
                ids: ["A", "B"]
            )
        )
        observer.emit(.defaultInputChanged)
        try await Task.sleep(for: .milliseconds(120))

        let startedIDs = await avf.startedDeviceIDs()
        XCTAssertEqual(startedIDs, ["A", "B"])
        let runtime = await provider.runtimeSnapshot()
        XCTAssertEqual(
            runtime.telemetry.automaticRecoveryAttemptCount,
            0
        )
        await provider.stop()
    }

    func testUnrelatedAVFoundationConnectionDoesNotRestartExplicitMicrophone()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A"]
            )
        )
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:A",
            legacyAVFoundationID: "A",
            coreAudioUID: nil
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            preferredInputProvider: { preferred },
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        discovery.set(
            snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A", "B"]
            )
        )
        observer.emit(.avFoundationConnected(uniqueID: "B"))
        try await Task.sleep(for: .milliseconds(80))

        let avfStarts = await avf.startCount()
        XCTAssertEqual(avfStarts, 1)
        await provider.stop()
    }

    func testActiveAVFoundationDisconnectTriggersRediscovery()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: mergedSameIDSnapshot(
                avfIsDefault: true,
                coreAudioIsDefault: true
            )
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        discovery.set(
            AudioInputDiscoverySnapshot(
                avFoundationInputs: [],
                coreAudioInputs: [
                    CoreAudioInputDevice(
                        deviceID: AudioDeviceID(42),
                        uid: "same-id",
                        name: "Same Microphone",
                        isAlive: true,
                        inputChannelCount: 1,
                        isSystemDefault: true
                    )
                ]
            )
        )
        observer.emit(.avFoundationDisconnected(uniqueID: "same-id"))
        try await Task.sleep(for: .milliseconds(120))

        let avfStartedIDs = await avf.startedDeviceIDs()
        let coreAudioStartedIDs = await coreAudio.startedDeviceIDs()
        XCTAssertEqual(avfStartedIDs, ["same-id"])
        XCTAssertEqual(coreAudioStartedIDs, ["same-id"])
        await provider.stop()
    }

    func testExplicitPreferredReconnectReplacesFallback() async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "B",
                ids: ["B"]
            )
        )
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:A",
            legacyAVFoundationID: "A",
            coreAudioUID: nil
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            preferredInputProvider: { preferred },
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        let initialStartedIDs = await avf.startedDeviceIDs()
        XCTAssertEqual(initialStartedIDs, ["B"])
        discovery.set(
            snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A", "B"]
            )
        )
        observer.emit(.avFoundationConnected(uniqueID: "A"))
        try await Task.sleep(for: .milliseconds(120))

        let reconnectedStartedIDs = await avf.startedDeviceIDs()
        let avfStops = await avf.stopCount()
        XCTAssertEqual(reconnectedStartedIDs, ["B", "A"])
        XCTAssertGreaterThanOrEqual(avfStops, 1)
        await provider.stop()
    }

    func testCoreAudioDeviceListChangeDoesNotRestartPresentCoreAudioDevice()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithCoreAudioDevices(
                defaultUID: "ca-a",
                uids: ["ca-a"]
            )
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        discovery.set(
            snapshotWithCoreAudioDevices(
                defaultUID: "ca-a",
                uids: ["ca-a", "ca-b"]
            )
        )
        observer.emit(.coreAudioDeviceListChanged)
        try await Task.sleep(for: .milliseconds(80))

        let coreAudioStarts = await coreAudio.startCount()
        let coreAudioStops = await coreAudio.stopCount()
        XCTAssertEqual(coreAudioStarts, 1)
        XCTAssertEqual(coreAudioStops, 0)
        await provider.stop()
    }

    func testApplicationForegroundWithUnchangedTopologyDoesNotRestart()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A"]
            )
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            hardwareObserver: observer
        )

        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        observer.emit(.applicationBecameActive)
        try await Task.sleep(for: .milliseconds(80))

        let avfStarts = await avf.startCount()
        let avfStops = await avf.stopCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(avfStops, 0)
        await provider.stop()
    }

    func testPermissionRevokedOnForegroundTerminatesWithoutCoreAudioFallback()
        async throws {
        let avf = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let coreAudio = FakeMicrophoneBackendProvider(mode: .yieldsSamples)
        let permission = MutablePermissionChecker(status: .authorized)
        let discovery = MutableAudioInputDiscoveryProvider(
            snapshot: snapshotWithAVFDevices(
                defaultID: "A",
                ids: ["A"]
            )
        )
        let observer = EmittingHardwareObserver()
        let provider = makeProvider(
            avfProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: discovery,
            permission: permission,
            hardwareObserver: observer
        )
        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first)

        permission.set(.denied)
        observer.emit(.applicationBecameActive)

        do {
            _ = try await iterator.next()
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .permissionDenied
            )
        }
        let coreAudioStarts = await coreAudio.startCount()
        XCTAssertEqual(coreAudioStarts, 0)
        await provider.stop()
    }

    func testReconnectClearsOnlyTheMatchingBackendAttempt() {
        let preferred = PreferredAudioInput(
            backend: .automatic,
            stableID: "avf:A",
            legacyAVFoundationID: "A",
            coreAudioUID: nil
        )
        let current = ResolvedMicrophoneCapture(
            plan: .avFoundation(deviceID: "B"),
            kind: .fallback(unavailablePreferredID: "A"),
            device: AudioInputDevice(
                id: "B",
                name: "B",
                manufacturer: "Test",
                isConnected: true,
                isSuspended: false,
                isInUseByAnotherApplication: false,
                isSystemDefault: true,
                avFoundationUniqueID: "B",
                isAVFoundationAvailable: true
            )
        )
        let attempted: Set<MicrophoneCaptureAttemptKey> = [
            MicrophoneCaptureAttemptKey(
                physicalStableID: "avf:A",
                backend: .avFoundation
            ),
            MicrophoneCaptureAttemptKey(
                physicalStableID: "ca:B",
                backend: .coreAudioFallback
            ),
        ]
        let fresh = snapshotWithAVFDevices(
            defaultID: "A",
            ids: ["A", "B"]
        )

        let decision = MicrophoneHardwareChangePolicy.decision(
            event: .avFoundationConnected(uniqueID: "A"),
            preferred: preferred,
            currentResolution: current,
            previousSnapshot: snapshotWithAVFDevices(
                defaultID: "B",
                ids: ["B"]
            ),
            freshSnapshot: fresh,
            attemptedCaptures: attempted
        )

        XCTAssertEqual(
            decision,
            .rediscoverClearing(
                [
                    MicrophoneCaptureAttemptKey(
                        physicalStableID: "avf:A",
                        backend: .avFoundation
                    )
                ]
            )
        )
    }

    func testResolvedSubsystemUsesBundleIdentifierOrFallback() {
        XCTAssertEqual(
            MicrophoneDiagnosticLogger.resolvedSubsystem(
                bundleIdentifier:
                    "com.shenminghao.MeetingNotes.beta"
            ),
            "com.shenminghao.MeetingNotes.beta"
        )
        XCTAssertEqual(
            MicrophoneDiagnosticLogger.resolvedSubsystem(
                bundleIdentifier: nil
            ),
            "com.shenminghao.MeetingNotes"
        )
    }

    private func snapshotWithAVFDevices(
        defaultID: String?,
        ids: [String]
    ) -> AudioInputDiscoverySnapshot {
        AudioInputDiscoverySnapshot(
            avFoundationInputs: ids.map { id in
                AVFoundationInputDevice(
                    uniqueID: id,
                    name: "Mic \(id)",
                    manufacturer: "Apple",
                    isConnected: true,
                    isSuspended: false,
                    isInUseByAnotherApplication: false,
                    isSystemDefault: id == defaultID
                )
            },
            coreAudioInputs: []
        )
    }

    private func snapshotWithCoreAudioDevices(
        defaultUID: String?,
        uids: [String]
    ) -> AudioInputDiscoverySnapshot {
        AudioInputDiscoverySnapshot(
            avFoundationInputs: [],
            coreAudioInputs: uids.enumerated().map { index, uid in
                CoreAudioInputDevice(
                    deviceID: AudioDeviceID(1_000 + index),
                    uid: uid,
                    name: "Mic \(uid)",
                    isAlive: true,
                    inputChannelCount: 1,
                    isSystemDefault: uid == defaultUID
                )
            }
        )
    }

    private func mergedSameIDSnapshot(
        avfIsDefault: Bool,
        coreAudioIsDefault: Bool
    ) -> AudioInputDiscoverySnapshot {
        AudioInputDiscoverySnapshot(
            avFoundationInputs: [
                AVFoundationInputDevice(
                    uniqueID: "same-id",
                    name: "Same Microphone",
                    manufacturer: "Apple",
                    isConnected: true,
                    isSuspended: false,
                    isInUseByAnotherApplication: false,
                    isSystemDefault: avfIsDefault
                )
            ],
            coreAudioInputs: [
                CoreAudioInputDevice(
                    deviceID: AudioDeviceID(42),
                    uid: "same-id",
                    name: "Same Microphone",
                    isAlive: true,
                    inputChannelCount: 1,
                    isSystemDefault: coreAudioIsDefault
                )
            ]
        )
    }

    private func makeProvider(
        avfProvider: any MicrophoneSampleProviding,
        coreAudioProvider: any MicrophoneSampleProviding,
        discovery: any AudioInputDeviceProviding,
        permission: any MicrophonePermissionChecking =
            StaticMicrophonePermissionChecker(status: .authorized),
        preferredInputProvider:
            @escaping @Sendable () -> PreferredAudioInput = {
                .automatic
            },
        hardwareObserver: any CoreAudioInputHardwareObserving =
            NoopHardwareObserver(),
        configuration: MicrophoneRecoveryConfiguration =
            MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(40),
                maxAutomaticRecoveryAttempts: 2
            )
    ) -> AdaptiveMicrophoneSampleProvider {
        AdaptiveMicrophoneSampleProvider(
            avFoundationProvider: avfProvider,
            coreAudioProvider: coreAudioProvider,
            discovery: discovery,
            permission: permission,
            preferredInputProvider: preferredInputProvider,
            hardwareObserver: hardwareObserver,
            configuration: configuration
        )
    }

    private func firstSample(
        from provider: AdaptiveMicrophoneSampleProvider
    ) async throws -> MicrophoneSample? {
        let stream = try await provider.start(deviceID: nil)
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
    }

    private func snapshotWithAVFoundationDefault(
        uniqueID: String = "built-in",
        includeCoreAudioFallback: Bool = false
    ) -> AudioInputDiscoverySnapshot {
        AudioInputDiscoverySnapshot(
            avFoundationInputs: [
                AVFoundationInputDevice(
                    uniqueID: uniqueID,
                    name: "Built-in Microphone",
                    manufacturer: "Apple",
                    isConnected: true,
                    isSuspended: false,
                    isInUseByAnotherApplication: false,
                    isSystemDefault: true
                )
            ],
            coreAudioInputs: includeCoreAudioFallback
                ? [
                    CoreAudioInputDevice(
                        deviceID: AudioDeviceID(42),
                        uid: "built-in-mic",
                        name: "USB 麦克风",
                        isAlive: true,
                        inputChannelCount: 1,
                        isSystemDefault: true
                    )
                ]
                : []
        )
    }

    private func hasOverlappingActiveProviders(
        _ events: [BackendEvent]
    ) -> Bool {
        var active = false
        for event in events {
            switch event.kind {
            case .start:
                if active { return true }
                active = true
            case .stop:
                active = false
            }
        }
        return active
    }
}

private struct BackendEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case start
        case stop
    }

    let sequence: Int
    let kind: Kind
}

private enum FakeMicrophoneBackendMode: Sendable {
    case yieldsSamples
    case neverYields
    case startFails
    case failsAfterStart
}

private actor FakeMicrophoneBackendProvider: MicrophoneSampleProviding {
    private let mode: FakeMicrophoneBackendMode
    private var startError: Error?
    private var startedIDs: [String?] = []
    private var stops = 0
    private var events: [BackendEvent] = []
    private var sequenceCounter = 0
    private var handler: AsyncThrowingStream<
        MicrophoneSample,
        Error
    >.Continuation?

    init(
        mode: FakeMicrophoneBackendMode,
        startError: Error? = nil
    ) {
        self.mode = mode
        self.startError = startError
    }

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        startedIDs.append(deviceID)
        record(.start)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if case .startFails = mode {
            throw startError ?? MicrophoneCaptureError.runtimeFailure
        }
        let pair = AsyncThrowingStream<
            MicrophoneSample,
            Error
        >.makeStream()
        handler = pair.continuation
        if case .yieldsSamples = mode {
            let sample = try makeSample()
            pair.continuation.yield(sample)
        }
        if case .failsAfterStart = mode {
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000)
                self.handler?.finish(
                    throwing: MicrophoneCaptureError.deviceDisconnected
                )
            }
        }
        return pair.stream
    }

    func pause() async throws {}

    func resume() async throws {}

    func stop() async {
        stops += 1
        record(.stop)
        handler?.finish()
        handler = nil
    }

    func startCount() -> Int {
        startedIDs.count
    }

    func stopCount() -> Int {
        stops
    }

    func startedDeviceIDs() -> [String?] {
        startedIDs
    }

    func eventSequence() -> [BackendEvent] {
        events
    }

    func waitUntilStarted() async {
        guard startedIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func record(_ kind: BackendEvent.Kind) {
        sequenceCounter += 1
        events.append(
            BackendEvent(sequence: sequenceCounter, kind: kind)
        )
    }

    private func makeSample() throws -> MicrophoneSample {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 1
              ) else {
            throw MicrophoneCaptureError.runtimeFailure
        }
        buffer.frameLength = 1
        buffer.floatChannelData?.pointee[0] = 0.25
        return MicrophoneSample(
            buffer: buffer,
            sampleTime: 0,
            sampleRate: 48_000
        )
    }

    private var startWaiters:
        [CheckedContinuation<Void, Never>] = []
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

private final class SequencedAudioInputDiscoveryProvider:
    AudioInputDeviceProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [AudioInputDiscoverySnapshot]
    private var index = 0

    init(snapshots: [AudioInputDiscoverySnapshot]) {
        self.snapshots = snapshots
    }

    func discover() throws -> AudioInputDiscoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }
}

private struct NoopHardwareObserver: CoreAudioInputHardwareObserving {
    func events() -> AsyncStream<MicrophoneHardwareChangeEvent> {
        AsyncStream { _ in }
    }
}

private final class EmittingHardwareObserver:
    CoreAudioInputHardwareObserving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuations:
        [UUID: AsyncStream<MicrophoneHardwareChangeEvent>.Continuation] =
            [:]

    func events() -> AsyncStream<MicrophoneHardwareChangeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func emit(_ event: MicrophoneHardwareChangeEvent) {
        lock.lock()
        let continuations = Array(continuations.values)
        lock.unlock()
        continuations.forEach { $0.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

private final class MutableAudioInputDiscoveryProvider:
    AudioInputDeviceProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotValue: AudioInputDiscoverySnapshot

    init(snapshot: AudioInputDiscoverySnapshot) {
        snapshotValue = snapshot
    }

    func set(_ snapshot: AudioInputDiscoverySnapshot) {
        lock.lock()
        snapshotValue = snapshot
        lock.unlock()
    }

    func discover() throws -> AudioInputDiscoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }
}

private final class MutablePermissionChecker:
    MicrophonePermissionChecking,
    @unchecked Sendable {
    private let lock = NSLock()
    private var statusValue: CapturePermissionStatus

    init(status: CapturePermissionStatus) {
        statusValue = status
    }

    func set(_ status: CapturePermissionStatus) {
        lock.lock()
        statusValue = status
        lock.unlock()
    }

    func status() -> CapturePermissionStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusValue
    }
}

final class MicrophoneSampleTimelineNormalizerTests: XCTestCase {
    func testTimelineContinuesAcrossUnrelatedBackendSampleTimeOrigins()
        throws {
        var normalizer = MicrophoneSampleTimelineNormalizer()
        normalizer.reset()
        normalizer.beginBackend()

        let firstBackendFirst = try makeSample(
            sampleRate: 48_000,
            sampleTime: 480_000,
            frameLength: 480
        )
        let normalizedFirst =
            normalizer.normalize(firstBackendFirst)
        XCTAssertEqual(
            try XCTUnwrap(normalizedFirst.timestamp),
            0.0,
            accuracy: 0.000_1
        )

        let firstBackendSecond = try makeSample(
            sampleRate: 48_000,
            sampleTime: 480_480,
            frameLength: 480
        )
        let normalizedSecond =
            normalizer.normalize(firstBackendSecond)
        XCTAssertEqual(
            try XCTUnwrap(normalizedSecond.timestamp),
            0.01,
            accuracy: 0.000_1
        )

        normalizer.beginBackend()

        let secondBackendFirst = try makeSample(
            sampleRate: 48_000,
            sampleTime: 50_000_000,
            frameLength: 480
        )
        let normalizedThird =
            normalizer.normalize(secondBackendFirst)
        XCTAssertEqual(
            try XCTUnwrap(normalizedThird.timestamp),
            0.02,
            accuracy: 0.000_1
        )

        let secondBackendSecond = try makeSample(
            sampleRate: 48_000,
            sampleTime: 50_000_480,
            frameLength: 480
        )
        let normalizedFourth =
            normalizer.normalize(secondBackendSecond)
        XCTAssertEqual(
            try XCTUnwrap(normalizedFourth.timestamp),
            0.03,
            accuracy: 0.000_1
        )
    }

    func testTimelineRemainsContinuousWhenFallbackSampleRateChanges()
        throws {
        var normalizer = MicrophoneSampleTimelineNormalizer()
        normalizer.reset()
        normalizer.beginBackend()

        let firstBackendFirst = try makeSample(
            sampleRate: 48_000,
            sampleTime: 480_000,
            frameLength: 480
        )
        let first = try XCTUnwrap(
            normalizer.normalize(firstBackendFirst).timestamp
        )
        XCTAssertEqual(first, 0.0, accuracy: 0.000_1)

        let firstBackendSecond = try makeSample(
            sampleRate: 48_000,
            sampleTime: 480_480,
            frameLength: 480
        )
        let second = try XCTUnwrap(
            normalizer.normalize(firstBackendSecond).timestamp
        )
        XCTAssertEqual(second, 0.01, accuracy: 0.000_1)

        normalizer.beginBackend()

        let secondBackendFirst = try makeSample(
            sampleRate: 44_100,
            sampleTime: 44_100_000,
            frameLength: 441
        )
        let third = try XCTUnwrap(
            normalizer.normalize(secondBackendFirst).timestamp
        )
        XCTAssertEqual(third, 0.02, accuracy: 0.000_1)

        let secondBackendSecond = try makeSample(
            sampleRate: 44_100,
            sampleTime: 44_100_441,
            frameLength: 441
        )
        let fourth = try XCTUnwrap(
            normalizer.normalize(secondBackendSecond).timestamp
        )
        XCTAssertEqual(fourth, 0.03, accuracy: 0.000_1)
    }

    func testTimelineNeverMovesBackward() throws {
        var normalizer = MicrophoneSampleTimelineNormalizer()
        normalizer.reset()
        normalizer.beginBackend()

        let firstFrame = try makeSample(
            sampleRate: 48_000,
            sampleTime: 100_000,
            frameLength: 480
        )
        let first = try XCTUnwrap(
            normalizer.normalize(firstFrame).timestamp
        )

        let backwardFrame = try makeSample(
            sampleRate: 48_000,
            sampleTime: 50_000,
            frameLength: 480
        )
        let second = try XCTUnwrap(
            normalizer.normalize(backwardFrame).timestamp
        )

        let repeatedOriginFrame = try makeSample(
            sampleRate: 48_000,
            sampleTime: 100_000,
            frameLength: 480
        )
        let third = try XCTUnwrap(
            normalizer.normalize(repeatedOriginFrame).timestamp
        )

        XCTAssertEqual(first, 0.0, accuracy: 0.000_1)
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertGreaterThanOrEqual(third, second)
        XCTAssertGreaterThanOrEqual(second, 0.009_9)
    }

    private func makeSample(
        sampleRate: Double,
        sampleTime: AVAudioFramePosition,
        frameLength: AVAudioFrameCount
    ) throws -> MicrophoneSample {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameLength
            )
        )
        buffer.frameLength = frameLength
        return MicrophoneSample(
            buffer: buffer,
            sampleTime: sampleTime,
            sampleRate: sampleRate
        )
    }
}
