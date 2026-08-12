import AppKit
import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class AudioDeviceCatalogTests: XCTestCase {
    func testInjectedProvidersProduceSnapshot() async throws {
        let microphone = input(id: "microphone", name: "Microphone")
        let speaker = output(id: "speaker", name: "Speaker")
        let catalog = AudioDeviceCatalog(
            inputProvider: { [microphone] },
            outputProvider: { [speaker] }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs, [microphone])
        XCTAssertEqual(snapshot.outputs, [speaker])
    }

    func testSnapshotSortsByLocalizedNameThenStableID() async throws {
        let inputs = [
            input(id: "z-id", name: "Zulu"),
            input(id: "b-id", name: "Alpha"),
            input(id: "a-id", name: "Alpha")
        ]
        let outputs = [
            output(id: "z-id", name: "Zulu"),
            output(id: "b-id", name: "Alpha"),
            output(id: "a-id", name: "Alpha")
        ]
        let catalog = AudioDeviceCatalog(
            inputProvider: { inputs },
            outputProvider: { outputs }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs.map(\.id), ["a-id", "b-id", "z-id"])
        XCTAssertEqual(snapshot.outputs.map(\.id), ["a-id", "b-id", "z-id"])
    }

    func testDuplicateStableIDsRetainFirstProviderOccurrence() async throws {
        let firstInput = input(
            id: "duplicate",
            name: "First input",
            manufacturer: "First manufacturer",
            isConnected: false,
            isSuspended: true,
            isInUseByAnotherApplication: true,
            isSystemDefault: true
        )
        let firstOutput = output(
            id: "duplicate",
            name: "First output",
            isConnected: false,
            isSystemDefault: true
        )
        let inputs = [
            firstInput,
            input(id: "duplicate", name: "Second input")
        ]
        let outputs = [
            firstOutput,
            output(id: "duplicate", name: "Second output")
        ]
        let catalog = AudioDeviceCatalog(
            inputProvider: { inputs },
            outputProvider: { outputs }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs, [firstInput])
        XCTAssertEqual(snapshot.outputs, [firstOutput])
    }

    func testWhitespaceOnlyNamesNormalizeToUnnamedDeviceLabel() async throws {
        let microphone = input(id: "input", name: " \n\t ")
        let speaker = output(id: "output", name: "\t ")
        let catalog = AudioDeviceCatalog(
            inputProvider: { [microphone] },
            outputProvider: { [speaker] }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs.first?.name, "未命名音频设备")
        XCTAssertEqual(snapshot.outputs.first?.name, "未命名音频设备")
    }

    func testNonEmptyNamesAreTrimmedBeforeDisplayAndSorting() async throws {
        let inputs = [
            input(id: "z-input", name: " \nZulu\t"),
            input(id: "a-input", name: "Alpha")
        ]
        let outputs = [
            output(id: "z-output", name: " \nZulu\t"),
            output(id: "a-output", name: "Alpha")
        ]
        let catalog = AudioDeviceCatalog(
            inputProvider: { inputs },
            outputProvider: { outputs }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs.map(\.id), ["a-input", "z-input"])
        XCTAssertEqual(snapshot.inputs.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(snapshot.outputs.map(\.id), ["a-output", "z-output"])
        XCTAssertEqual(snapshot.outputs.map(\.name), ["Alpha", "Zulu"])
    }

    func testInputAndOutputFactsArePreserved() async throws {
        let microphone = input(
            id: "input",
            name: "Input",
            manufacturer: "Acme",
            isConnected: false,
            isSuspended: true,
            isInUseByAnotherApplication: true,
            isSystemDefault: true
        )
        let speaker = output(
            id: "output",
            name: "Output",
            isConnected: false,
            isSystemDefault: true
        )
        let catalog = AudioDeviceCatalog(
            inputProvider: { [microphone] },
            outputProvider: { [speaker] }
        )

        let snapshot = try await catalog.snapshot()

        XCTAssertEqual(snapshot.inputs, [microphone])
        XCTAssertEqual(snapshot.outputs, [speaker])
    }

    func testInputNormalizationPreservesBackendIdentityMetadata()
        async throws {
        let microphone = AudioInputDevice(
            id: "same-id",
            name: "  Merged Mic  ",
            manufacturer: "Apple",
            isConnected: true,
            isSuspended: false,
            isInUseByAnotherApplication: false,
            isSystemDefault: true,
            avFoundationUniqueID: "same-id",
            coreAudioUID: "same-id",
            coreAudioDeviceID: AudioDeviceID(42),
            inputChannelCount: 2,
            isAVFoundationAvailable: true,
            isCoreAudioAvailable: true
        )
        let catalog = AudioDeviceCatalog(
            inputProvider: { [microphone] },
            outputProvider: { [] }
        )

        let snapshot = try await catalog.snapshot()
        let normalized = try XCTUnwrap(snapshot.inputs.first)

        XCTAssertEqual(normalized.id, "same-id")
        XCTAssertEqual(normalized.name, "Merged Mic")
        XCTAssertEqual(normalized.avFoundationUniqueID, "same-id")
        XCTAssertEqual(normalized.coreAudioUID, "same-id")
        XCTAssertEqual(normalized.coreAudioDeviceID, AudioDeviceID(42))
        XCTAssertEqual(normalized.inputChannelCount, 2)
        XCTAssertTrue(normalized.isAVFoundationAvailable)
        XCTAssertTrue(normalized.isCoreAudioAvailable)
    }

    func testCoreAudioInputEnumerationSkipsMalformedDeviceAndKeepsValidDevice()
        throws {
        let devices = CoreAudioDeviceProvider.buildInputDevices(
            deviceIDs: [AudioDeviceID(100), AudioDeviceID(200)],
            defaultInputID: AudioDeviceID(200),
            channelCount: { deviceID in
                if deviceID == AudioDeviceID(100) {
                    throw AudioDeviceCatalogError
                        .invalidCoreAudioPropertyData(
                            objectID: 100,
                            selector: 1
                        )
                }
                return 1
            },
            uid: { deviceID in
                deviceID == AudioDeviceID(100)
                    ? "malformed" : "built-in"
            },
            name: { deviceID in
                deviceID == AudioDeviceID(100)
                    ? "Malformed" : "Built-in"
            },
            isAlive: { _ in true }
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, AudioDeviceID(200))
        XCTAssertEqual(devices.first?.isSystemDefault, true)
    }

    func testCoreAudioEnumerationDoesNotRequireDefaultInputID()
        throws {
        let devices = CoreAudioDeviceProvider.buildInputDevices(
            deviceIDs: [AudioDeviceID(200)],
            defaultInputID: nil,
            channelCount: { _ in 1 },
            uid: { _ in "built-in" },
            name: { _ in "Built-in" },
            isAlive: { _ in true }
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.deviceID, AudioDeviceID(200))
        XCTAssertEqual(devices.first?.isSystemDefault, false)
    }

    @MainActor
    func testObserverStartTwiceDoesNotDuplicateAndStopStops() {
        let center = NotificationCenter()
        let counter = CallCounter()
        let observer = CoreAudioDeviceChangeObserver(
            notificationCenter: center,
            isAudioCaptureDevice: { _ in true }
        )

        observer.start { counter.increment() }
        observer.start { counter.increment() }

        center.post(
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        XCTAssertEqual(counter.count(), 1)

        center.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertEqual(counter.count(), 2)

        observer.stop()
        center.post(
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        XCTAssertEqual(counter.count(), 2)
    }

    @MainActor
    func testObserverIgnoresNonAudioAVCaptureNotifications() {
        let center = NotificationCenter()
        let counter = CallCounter()
        let observer = CoreAudioDeviceChangeObserver(
            notificationCenter: center,
            isAudioCaptureDevice: { _ in false }
        )

        observer.start { counter.increment() }
        center.post(
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )

        XCTAssertEqual(counter.count(), 0)
        observer.stop()
    }

    func testProviderErrorPropagatesAsAudioDeviceCatalogError() async {
        let expected = AudioDeviceCatalogError.coreAudioPropertyReadFailed(
            objectID: 1,
            selector: 2,
            status: -1
        )
        let catalog = AudioDeviceCatalog(
            inputProvider: { throw expected },
            outputProvider: { [] }
        )

        do {
            _ = try await catalog.snapshot()
            XCTFail("Expected the provider error to propagate")
        } catch let error as AudioDeviceCatalogError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected AudioDeviceCatalogError, got \(error)")
        }
    }

    func testCatalogConformsToSendableDiscoveryProtocol() {
        let catalog = AudioDeviceCatalog(
            inputProvider: { [] },
            outputProvider: { [] }
        )

        requireSendable(catalog)
        requireAudioDeviceDiscovering(catalog)
    }

    func testCoreAudioBufferListParserAcceptsZeroBuffers() throws {
        let bytes = try bufferListBytes(channelCounts: [])

        XCTAssertEqual(try parseChannelCount(bytes), 0)
    }

    func testCoreAudioBufferListParserReadsOneBuffer() throws {
        let bytes = try bufferListBytes(channelCounts: [2])

        XCTAssertEqual(try parseChannelCount(bytes), 2)
    }

    func testCoreAudioBufferListParserSumsMultipleBuffers() throws {
        let bytes = try bufferListBytes(channelCounts: [1, 2, 4])

        XCTAssertEqual(try parseChannelCount(bytes), 7)
    }

    func testCoreAudioBufferListParserRejectsTruncatedHeader() throws {
        let buffersOffset = try XCTUnwrap(
            MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)
        )
        let bytes = [UInt8](
            repeating: 0,
            count: max(0, buffersOffset - 1)
        )

        assertInvalidBufferList(bytes)
    }

    func testCoreAudioBufferListParserRejectsTruncatedBuffers() throws {
        var bytes = try bufferListBytes(channelCounts: [2])
        bytes.removeLast()

        assertInvalidBufferList(bytes)
    }

    func testCoreAudioBufferListParserRejectsExaggeratedBufferCount() throws {
        let bytes = try bufferListBytes(
            channelCounts: [],
            declaredBufferCount: UInt32.max
        )

        assertInvalidBufferList(bytes)
    }

    func testCoreAudioBufferListParserRejectsChannelSumOverflow() throws {
        let bytes = try bufferListBytes(
            channelCounts: [UInt32.max, 1]
        )

        assertInvalidBufferList(bytes)
    }

    private func requireSendable<Value: Sendable>(_: Value) {}

    private func requireAudioDeviceDiscovering<Value: AudioDeviceDiscovering>(
        _: Value
    ) {}

    private func input(
        id: String,
        name: String,
        manufacturer: String = "Test",
        isConnected: Bool = true,
        isSuspended: Bool = false,
        isInUseByAnotherApplication: Bool = false,
        isSystemDefault: Bool = false
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name,
            manufacturer: manufacturer,
            isConnected: isConnected,
            isSuspended: isSuspended,
            isInUseByAnotherApplication: isInUseByAnotherApplication,
            isSystemDefault: isSystemDefault
        )
    }

    private func output(
        id: String,
        name: String,
        isConnected: Bool = true,
        isSystemDefault: Bool = false
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id,
            name: name,
            isConnected: isConnected,
            isSystemDefault: isSystemDefault
        )
    }

    private func bufferListBytes(
        channelCounts: [UInt32],
        declaredBufferCount: UInt32? = nil
    ) throws -> [UInt8] {
        let countOffset = try XCTUnwrap(
            MemoryLayout<AudioBufferList>.offset(of: \.mNumberBuffers)
        )
        let buffersOffset = try XCTUnwrap(
            MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)
        )
        let channelsOffset = try XCTUnwrap(
            MemoryLayout<AudioBuffer>.offset(of: \.mNumberChannels)
        )
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        var bytes = [UInt8](
            repeating: 0,
            count: buffersOffset + channelCounts.count * bufferStride
        )

        writeUInt32(
            declaredBufferCount ?? UInt32(channelCounts.count),
            to: &bytes,
            at: countOffset
        )
        for (index, channelCount) in channelCounts.enumerated() {
            writeUInt32(
                channelCount,
                to: &bytes,
                at: buffersOffset + index * bufferStride + channelsOffset
            )
        }
        return bytes
    }

    private func writeUInt32(
        _ value: UInt32,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        var value = value
        withUnsafeBytes(of: &value) { source in
            bytes.replaceSubrange(
                offset..<(offset + source.count),
                with: source
            )
        }
    }

    private func parseChannelCount(_ bytes: [UInt8]) throws -> UInt32 {
        try CoreAudioBufferListParser.channelCount(
            in: bytes,
            objectID: 42,
            selector: 99
        )
    }

    private func assertInvalidBufferList(
        _ bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try parseChannelCount(bytes),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AudioDeviceCatalogError,
                .invalidCoreAudioPropertyData(
                    objectID: 42,
                    selector: 99
                ),
                file: file,
                line: line
            )
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
