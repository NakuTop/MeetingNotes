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

    private func makeProvider(
        avfProvider: any MicrophoneSampleProviding,
        coreAudioProvider: any MicrophoneSampleProviding,
        discovery: any AudioInputDeviceProviding,
        permission: any MicrophonePermissionChecking =
            StaticMicrophonePermissionChecker(status: .authorized),
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
            preferredInputProvider: { .automatic },
            hardwareObserver: NoopHardwareObserver(),
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
    func events() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}
