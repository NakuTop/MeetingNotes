import Foundation
import XCTest
@testable import MeetingNotes

final class LiveMeetingCaptureFactoryTests: XCTestCase {
    func testOfflinePreferenceIsReadAgainForEveryNewCapture() async throws {
        let preference = SequencedAudioInputPreference(
            values: ["first-mic", "second-mic"]
        )
        let recorder = CaptureDeviceRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneFactory: { deviceID in
                recorder.record(deviceID)
                return FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { _ in
                FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .offline)
        _ = try await factory.makeCapture(for: .offline)

        XCTAssertEqual(recorder.deviceIDs(), ["first-mic", "second-mic"])
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testOnlinePreferenceIsReadAgainAndRoutedForEveryNewCapture()
        async throws {
        let preference = SequencedAudioInputPreference(
            values: ["first-online-mic", "second-online-mic"]
        )
        let offlineRecorder = CaptureDeviceRecorder()
        let onlineRecorder = CaptureDeviceRecorder()
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneFactory: { deviceID in
                offlineRecorder.record(deviceID)
                return FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { deviceID in
                onlineRecorder.record(deviceID)
                return FactoryTestCaptureSource(kind: .online)
            }
        )

        _ = try await factory.makeCapture(for: .online)
        _ = try await factory.makeCapture(for: .online)

        XCTAssertEqual(
            onlineRecorder.deviceIDs(),
            ["first-online-mic", "second-online-mic"]
        )
        XCTAssertTrue(offlineRecorder.deviceIDs().isEmpty)
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testOnlineNilPreferenceUsesSystemDefaultWithoutOfflineBuilder()
        async throws {
        let preference = SequencedAudioInputPreference(values: [nil])
        let offlineRecorder = CaptureDeviceRecorder()
        let onlineRecorder = CaptureDeviceRecorder()
        let online = FactoryTestCaptureSource(kind: .online)
        let factory = LiveMeetingCaptureFactory(
            audioInputDevicePreference: preference,
            microphoneFactory: { deviceID in
                offlineRecorder.record(deviceID)
                return FactoryTestCaptureSource(kind: .offline)
            },
            screenFactory: { deviceID in
                onlineRecorder.record(deviceID)
                return online
            }
        )

        let capture = try await factory.makeCapture(for: .online)

        XCTAssertTrue(capture as AnyObject === online)
        XCTAssertEqual(onlineRecorder.deviceIDs(), [nil])
        XCTAssertTrue(offlineRecorder.deviceIDs().isEmpty)
        let readCount = await preference.readCount()
        XCTAssertEqual(readCount, 1)
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
