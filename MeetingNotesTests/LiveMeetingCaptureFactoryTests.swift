import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import MeetingNotes

final class LiveMeetingCaptureFactoryTests: XCTestCase {
    func testOfflinePreferenceIsReadAgainForEveryNewCapture() async throws {
        let preference = SequencedPreferredAudioInputPreference(
            values: [.automatic, .automatic]
        )
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { preferred in
                recorder.recordPreferred(preferred)
                let provider = FactoryTestMicrophoneProvider()
                recorder.recordProvider(provider)
                return provider
            },
            microphoneCaptureFactory: { provider in
                recorder.recordCaptureProvider(provider)
                return FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { _ in
                FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .offline)
        _ = try await factory.makeCapture(for: .offline)

        XCTAssertEqual(
            recorder.recordedPreferredValues(),
            [.automatic, .automatic]
        )
        XCTAssertEqual(recorder.recordedProviderIdentities().count, 2)
        XCTAssertEqual(recorder.recordedCaptureProviderCount(), 2)
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testOnlinePreferenceIsReadAgainAndRoutedForEveryNewCapture()
        async throws {
        let preference = SequencedPreferredAudioInputPreference(
            values: [.automatic, .automatic]
        )
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { preferred in
                recorder.recordPreferred(preferred)
                let provider = FactoryTestMicrophoneProvider()
                recorder.recordProvider(provider)
                return provider
            },
            microphoneCaptureFactory: { provider in
                recorder.recordCaptureProvider(provider)
                let capture = FactoryTestCaptureSource(kind: .offline)
                recorder.recordCapture(capture)
                return capture
            },
            screenFactory: { microphoneCapture in
                recorder.recordScreen(microphoneCapture)
                return FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .online)
        _ = try await factory.makeCapture(for: .online)

        XCTAssertEqual(
            recorder.recordedPreferredValues(),
            [.automatic, .automatic]
        )
        XCTAssertEqual(recorder.recordedProviderIdentities().count, 2)
        XCTAssertEqual(recorder.recordedCaptureIdentities().count, 2)
        XCTAssertEqual(recorder.recordedScreenIdentities().count, 2)
        XCTAssertEqual(
            recorder.recordedCaptureIdentities(),
            recorder.recordedScreenIdentities()
        )
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testOnlineUsesAutomaticPreferenceWithoutLegacySCKitMicrophoneID()
        async throws {
        let preference = SequencedPreferredAudioInputPreference(
            values: [.automatic]
        )
        let recorder = PreferredInputRecorder()
        let online = FactoryTestCaptureSource(kind: .online)
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { preferred in
                recorder.recordPreferred(preferred)
                let provider = FactoryTestMicrophoneProvider()
                recorder.recordProvider(provider)
                return provider
            },
            microphoneCaptureFactory: { provider in
                recorder.recordCaptureProvider(provider)
                let capture = FactoryTestCaptureSource(kind: .offline)
                recorder.recordCapture(capture)
                return capture
            },
            screenFactory: { microphoneCapture in
                recorder.recordScreen(microphoneCapture)
                return online
            }
        )

        let capture = try await factory.makeCapture(for: .online)

        XCTAssertTrue(capture as AnyObject === online)
        XCTAssertEqual(recorder.recordedPreferredValues(), [.automatic])
        XCTAssertEqual(recorder.recordedProviderIdentities().count, 1)
        XCTAssertEqual(recorder.recordedCaptureIdentities().count, 1)
        XCTAssertEqual(recorder.recordedScreenIdentities().count, 1)
        XCTAssertEqual(
            recorder.recordedCaptureIdentities(),
            recorder.recordedScreenIdentities()
        )
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 1)
    }

    func testOfflineProductionProviderIsAdaptive() {
        let provider =
            LiveMeetingCaptureFactory
                .makeProductionMicrophoneProvider(
                    preferred: .automatic
                )

        XCTAssertTrue(provider is AdaptiveMicrophoneSampleProvider)
    }

    func testOfflineCapturePassesCompletePreferredAudioInputToProviderFactory()
        async throws {
        let preferred = PreferredAudioInput(
            backend: .coreAudio,
            stableID: "ca:usb-mic",
            legacyAVFoundationID: nil,
            coreAudioUID: "usb-mic"
        )
        let preference =
            StaticPreferredAudioInputPreference(value: preferred)
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { value in
                recorder.recordPreferred(value)
                return FactoryTestMicrophoneProvider()
            },
            microphoneCaptureFactory: { _ in
                FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { _ in
                FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .offline)

        XCTAssertEqual(recorder.recordedPreferredValues(), [preferred])
    }

    func testOfflineCreatesFreshMicrophoneProviderForEveryCapture()
        async throws {
        let preference = SequencedPreferredAudioInputPreference(
            values: [.automatic, .automatic]
        )
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { preferred in
                recorder.recordPreferred(preferred)
                let provider = FactoryTestMicrophoneProvider()
                recorder.recordProvider(provider)
                return provider
            },
            microphoneCaptureFactory: { _ in
                FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { _ in
                FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .offline)
        _ = try await factory.makeCapture(for: .offline)

        let identities = recorder.recordedProviderIdentities()
        XCTAssertEqual(identities.count, 2)
        XCTAssertNotEqual(identities[0], identities[1])
    }

    func testOnlineProductionMicrophoneProviderIsAdaptive() {
        let provider =
            LiveMeetingCaptureFactory
                .makeProductionMicrophoneProvider(
                    preferred: .automatic
                )

        XCTAssertTrue(provider is AdaptiveMicrophoneSampleProvider)
    }

    func testOnlinePassesCompletePreferredAudioInputToAdaptiveProviderFactory()
        async throws {
        let preferred = PreferredAudioInput(
            backend: .coreAudio,
            stableID: "ca:usb-mic",
            legacyAVFoundationID: nil,
            coreAudioUID: "usb-mic"
        )
        let preference =
            StaticPreferredAudioInputPreference(value: preferred)
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { value in
                recorder.recordPreferred(value)
                return FactoryTestMicrophoneProvider()
            },
            microphoneCaptureFactory: { _ in
                FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { _ in
                FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .online)

        XCTAssertEqual(recorder.recordedPreferredValues(), [preferred])
    }

    func testOnlineCreatesFreshMicrophoneProviderForEveryCapture()
        async throws {
        let preference = SequencedPreferredAudioInputPreference(
            values: [.automatic, .automatic]
        )
        let recorder = PreferredInputRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneProviderFactory: { preferred in
                recorder.recordPreferred(preferred)
                let provider = FactoryTestMicrophoneProvider()
                recorder.recordProvider(provider)
                return provider
            },
            microphoneCaptureFactory: { provider in
                recorder.recordCaptureProvider(provider)
                let capture = FactoryTestCaptureSource(kind: .offline)
                recorder.recordCapture(capture)
                return capture
            },
            screenFactory: { microphoneCapture in
                recorder.recordScreen(microphoneCapture)
                return FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .online)
        _ = try await factory.makeCapture(for: .online)

        let providerIdentities =
            recorder.recordedProviderIdentities()
        let captures = recorder.recordedCaptures()
        let captureIdentities = captures.map {
            ObjectIdentifier($0 as AnyObject)
        }
        XCTAssertEqual(providerIdentities.count, 2)
        XCTAssertNotEqual(providerIdentities[0], providerIdentities[1])
        XCTAssertEqual(captureIdentities.count, 2)
        XCTAssertNotEqual(captureIdentities[0], captureIdentities[1])
        XCTAssertEqual(recorder.recordedScreenIdentities().count, 2)
    }

    func testOnlineMixesSystemAudioWithCoreAudioFallbackMicrophoneWithoutDuplicateMic()
        async throws {
        let avf = ComposedThrowingAVFoundationMicrophoneProvider()
        let coreAudio = ComposedYieldingCoreAudioMicrophoneProvider()
        let adaptive = AdaptiveMicrophoneSampleProvider(
            avFoundationProvider: avf,
            coreAudioProvider: coreAudio,
            discovery: ComposedStaticDiscoveryProvider(),
            permission: ComposedPermissionChecker(),
            preferredInputProvider: { .automatic },
            hardwareObserver: ComposedNoopHardwareObserver(),
            configuration: MicrophoneRecoveryConfiguration(
                firstFrameTimeout: .milliseconds(40),
                maxAutomaticRecoveryAttempts: 2
            )
        )
        let microphoneCapture = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: adaptive
        )
        let microphoneStream =
            try await microphoneCapture.start()
        var microphoneIterator =
            microphoneStream.makeAsyncIterator()
        let nextPacket = try await microphoneIterator.next()
        let packet = try XCTUnwrap(nextPacket)
        let microphoneFrame = packet.master

        var synchronizer = ScreenAudioFrameSynchronizer(
            sessionStartedAt: 100
        )
        let systemFrame = CapturedAudioFrame(
            timestamp: 5_000,
            sampleRate: 48_000,
            samples: Array(repeating: 0.2, count: 480)
        )
        let orderedMicrophone = synchronizer.ingest(
            microphoneFrame,
            source: .microphone,
            receivedAt: 110
        )
        let orderedSystem = synchronizer.ingest(
            systemFrame,
            source: .system,
            receivedAt: 110
        )
        var mixer = RealtimeAudioMixer(
            windowSampleCount: 480,
            holdbackWindowCount: 10
        )
        let micMixed = try await mixer.ingest(
            orderedMicrophone[0],
            source: .microphone
        )
        let systemMixed = try await mixer.ingest(
            orderedSystem[0],
            source: .system
        )
        let mixed = try XCTUnwrap((micMixed + systemMixed).first)

        XCTAssertEqual(
            Set(mixed.sourceFrames.keys),
            [.microphone, .system]
        )
        let microphoneSamples = try XCTUnwrap(
            mixed.sourceFrames[.microphone]?.samples
        )
        let systemSamples = try XCTUnwrap(
            mixed.sourceFrames[.system]?.samples
        )
        XCTAssertEqual(microphoneSamples[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(systemSamples[0], 0.2, accuracy: 0.001)
        XCTAssertEqual(mixed.master.samples[0], 0.3, accuracy: 0.001)
        let avfStarts = avf.startCount()
        let coreAudioStarts = coreAudio.startCount()
        XCTAssertEqual(avfStarts, 1)
        XCTAssertEqual(coreAudioStarts, 1)
        await microphoneCapture.stop()
    }

    @MainActor
    func testMainActorPreferenceAdapterReadsLatestStoreValue() async {
        let suiteName = "LiveMeetingCaptureFactoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        let adapter = MainActorAudioInputDevicePreferenceAdapter(
            settingsStore: settings
        )
        settings.preferredInputDeviceID = "first-mic"

        let first = await adapter.preferredInputDeviceID()
        settings.preferredInputDeviceID = "second-mic"
        let second = await adapter.preferredInputDeviceID()

        XCTAssertEqual(first, "first-mic")
        XCTAssertEqual(second, "second-mic")
    }

    @MainActor
    func testInputPreferenceAdapterFallsBackWithoutOverwritingStoredDevice()
        async {
        let suiteName = "LiveMeetingCaptureFactoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        settings.preferredInputDeviceID = "disconnected-mic"
        let catalog = AudioDeviceCatalog(
            inputProvider: {
                [
                    AudioInputDevice(
                        id: "builtin-mic",
                        name: "Mac 麦克风",
                        manufacturer: "Apple",
                        isConnected: true,
                        isSuspended: false,
                        isInUseByAnotherApplication: false,
                        isSystemDefault: true
                    )
                ]
            },
            outputProvider: { [] }
        )
        let adapter = MainActorAudioInputDevicePreferenceAdapter(
            settingsStore: settings,
            deviceCatalog: catalog
        )

        let effectiveID = await adapter.preferredInputDeviceID()

        XCTAssertEqual(effectiveID, "builtin-mic")
        XCTAssertEqual(
            settings.preferredInputDeviceID,
            "disconnected-mic"
        )
    }

    @MainActor
    func testInputPreferenceAdapterUsesFirstUsableWhenNoDefaultIsMarked()
        async {
        let suiteName = "LiveMeetingCaptureFactoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        let catalog = AudioDeviceCatalog(
            inputProvider: {
                [
                    AudioInputDevice(
                        id: "first-usable-mic",
                        name: "USB 麦克风",
                        manufacturer: "Test",
                        isConnected: true,
                        isSuspended: false,
                        isInUseByAnotherApplication: false,
                        isSystemDefault: false
                    )
                ]
            },
            outputProvider: { [] }
        )
        let adapter = MainActorAudioInputDevicePreferenceAdapter(
            settingsStore: settings,
            deviceCatalog: catalog
        )

        let effectiveID = await adapter.preferredInputDeviceID()

        XCTAssertEqual(effectiveID, "first-usable-mic")
        XCTAssertNil(settings.preferredInputDeviceID)
    }
}

private actor SequencedAudioInputPreference:
    AudioInputDevicePreferenceReading {
    private let values: [String?]
    private var index = 0

    init(values: [String?]) {
        self.values = values
    }

    func preferredInputDeviceID() async -> String? {
        defer { index += 1 }
        guard !values.isEmpty else { return nil }
        return values[min(index, values.count - 1)]
    }

    func readCount() -> Int {
        index
    }
}

private actor SequencedPreferredAudioInputPreference:
    AudioInputDevicePreferenceReading {
    private let values: [PreferredAudioInput]
    private var index = 0

    init(values: [PreferredAudioInput]) {
        self.values = values
    }

    func preferredInputDeviceID() async -> String? {
        await preferredAudioInput().legacyDisplayID
    }

    func preferredAudioInput() async -> PreferredAudioInput {
        defer { index += 1 }
        guard !values.isEmpty else { return .automatic }
        return values[min(index, values.count - 1)]
    }

    func readCount() -> Int {
        index
    }
}

private struct StaticPreferredAudioInputPreference:
    AudioInputDevicePreferenceReading {
    let value: PreferredAudioInput

    func preferredInputDeviceID() async -> String? {
        value.legacyDisplayID
    }

    func preferredAudioInput() async -> PreferredAudioInput {
        value
    }
}

private final class CaptureDeviceRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []

    func record(_ value: String?) {
        lock.withLock {
            values.append(value)
        }
    }

    func deviceIDs() -> [String?] {
        lock.withLock { values }
    }
}

private final class PreferredInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var preferredValues: [PreferredAudioInput] = []
    private var providers: [FactoryTestMicrophoneProvider] = []
    private var captureProviderCount = 0
    private var captures: [any AudioCaptureSource] = []
    private var screenIdentities: [ObjectIdentifier] = []

    func recordPreferred(_ value: PreferredAudioInput) {
        lock.withLock {
            preferredValues.append(value)
        }
    }

    func recordProvider(_ provider: FactoryTestMicrophoneProvider) {
        lock.withLock {
            providers.append(provider)
        }
    }

    func recordCaptureProvider(_ provider: any MicrophoneSampleProviding) {
        lock.withLock {
            _ = provider
            captureProviderCount += 1
        }
    }

    func recordCapture(_ capture: any AudioCaptureSource) {
        lock.withLock {
            captures.append(capture)
        }
    }

    func recordScreen(_ capture: any AudioCaptureSource) {
        lock.withLock {
            screenIdentities.append(
                ObjectIdentifier(capture as AnyObject)
            )
        }
    }

    func recordedPreferredValues() -> [PreferredAudioInput] {
        lock.withLock { preferredValues }
    }

    func recordedProviderIdentities() -> [ObjectIdentifier] {
        lock.withLock {
            providers.map { ObjectIdentifier($0) }
        }
    }

    func recordedCaptureProviderCount() -> Int {
        lock.withLock { captureProviderCount }
    }

    func recordedCaptures() -> [any AudioCaptureSource] {
        lock.withLock { captures }
    }

    func recordedCaptureIdentities() -> [ObjectIdentifier] {
        lock.withLock {
            captures.map { ObjectIdentifier($0 as AnyObject) }
        }
    }

    func recordedScreenIdentities() -> [ObjectIdentifier] {
        lock.withLock { screenIdentities }
    }
}

private final class FactoryTestMicrophoneProvider:
    MicrophoneSampleProviding,
    @unchecked Sendable {
    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async {}
}

private final class ComposedThrowingAVFoundationMicrophoneProvider:
    MicrophoneSampleProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        lock.withLock {
            starts += 1
        }
        throw MicrophoneCaptureError.unableToStartSession
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async {}

    func startCount() -> Int {
        lock.withLock { starts }
    }
}

private final class ComposedYieldingCoreAudioMicrophoneProvider:
    MicrophoneSampleProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        lock.withLock {
            starts += 1
        }
        let pair = AsyncThrowingStream<
            MicrophoneSample,
            Error
        >.makeStream()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 480
              ) else {
            pair.continuation.finish(
                throwing: MicrophoneCaptureError.runtimeFailure
            )
            return pair.stream
        }
        buffer.frameLength = 480
        let channel = buffer.floatChannelData?.pointee
        for index in 0..<480 {
            channel?[index] = 0.1
        }
        pair.continuation.yield(
            MicrophoneSample(
                buffer: buffer,
                sampleTime: 0,
                sampleRate: 48_000
            )
        )
        return pair.stream
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async {}

    func startCount() -> Int {
        lock.withLock { starts }
    }
}

private struct ComposedStaticDiscoveryProvider:
    AudioInputDeviceProviding {
    func discover() throws -> AudioInputDiscoverySnapshot {
        AudioInputDiscoverySnapshot(
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
    }
}

private struct ComposedPermissionChecker:
    MicrophonePermissionChecking {
    func status() -> CapturePermissionStatus {
        .authorized
    }
}

private struct ComposedNoopHardwareObserver:
    CoreAudioInputHardwareObserving {
    func events() -> AsyncStream<MicrophoneHardwareChangeEvent> {
        AsyncStream { _ in }
    }
}

private final class FactoryTestCaptureSource:
    AudioCaptureSource,
    @unchecked Sendable {
    enum Kind {
        case offline
        case online
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    func start() async throws
        -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async {}
}
