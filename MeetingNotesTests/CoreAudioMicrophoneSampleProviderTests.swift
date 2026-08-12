import AVFoundation
import CoreAudio
import XCTest
@testable import MeetingNotes

final class CoreAudioMicrophoneSampleProviderTests: XCTestCase {
    func testProviderConfiguresResolvedDeviceAndDeliversSamples() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["external-mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let buffer = try makeBuffer(samples: [0.3, -0.2, 0.5])

        let stream = try await provider.start(deviceID: "external-mic")
        await session.emit(
            .buffer(buffer, AVAudioFramePosition(4_800), 48_000)
        )

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let sample = try XCTUnwrap(next)
        let configuredIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredIDs, [AudioDeviceID(42)])
        XCTAssertEqual(sample.sampleTime, 4_800)
        XCTAssertEqual(sample.sampleRate, 48_000)
        XCTAssertEqual(sample.buffer.frameLength, 3)
        await provider.stop()
    }

    func testNilDeviceIDUsesSystemDefaultInput() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(7)
            )
        )

        _ = try await provider.start(deviceID: nil)

        let configuredIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredIDs, [AudioDeviceID(7)])
        await provider.stop()
    }

    func testRequestedCoreAudioUIDDoesNotSilentlyUseDefaultWhenMissing()
        async {
        let session = FakeCoreAudioMicrophoneSession()
        let resolver = LiveCoreAudioDeviceIDResolver(
            inputsProvider: {
                [
                    CoreAudioInputDevice(
                        deviceID: AudioDeviceID(7),
                        uid: "default-uid",
                        name: "Default Mic",
                        isAlive: true,
                        inputChannelCount: 1,
                        isSystemDefault: true
                    )
                ]
            }
        )
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: resolver
        )

        do {
            _ = try await provider.start(deviceID: "missing-uid")
            XCTFail("Expected selectedDeviceUnavailable")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .selectedDeviceUnavailable
            )
        }

        let configuredIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredIDs, [])
    }

    func testStartFailureStopsSessionAndCanRetry() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        await session.setStartError(CoreAudioSessionTestError.startFailed)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected start failure")
        } catch {
            XCTAssertEqual(
                error as? CoreAudioSessionTestError,
                .startFailed
            )
        }
        let stopsAfterFailure = await session.stopCount()
        XCTAssertEqual(stopsAfterFailure, 1)

        await session.setStartError(nil)
        let stream = try await provider.start(deviceID: nil)
        withExtendedLifetime(stream) {}
        await provider.stop()
        let finalStops = await session.stopCount()
        XCTAssertEqual(finalStops, 2)
    }

    func testDoubleStartIsRejected() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected already running")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .alreadyRunning)
        }
        withExtendedLifetime(stream) {}
        await provider.stop()
    }

    func testStopIsIdempotentAndStopsSessionExactlyOnce() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        await provider.stop()
        await provider.stop()

        let stops = await session.stopCount()
        XCTAssertEqual(stops, 1)
        var iterator = stream.makeAsyncIterator()
        let firstAfterStop = try await iterator.next()
        let secondAfterStop = try await iterator.next()
        XCTAssertNil(firstAfterStop)
        XCTAssertNil(secondAfterStop)
    }

    func testPauseResumeForwardAndAreIdempotent() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        let stream = try await provider.start(deviceID: nil)

        try await provider.pause()
        try await provider.pause()
        try await provider.resume()
        try await provider.resume()

        let pauses = await session.pauseCount()
        let resumes = await session.resumeCount()
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(resumes, 1)
        withExtendedLifetime(stream) {}
        await provider.stop()
    }

    func testStreamTerminationStopsSessionExactlyOnce() async throws {
        let session = FakeCoreAudioMicrophoneSession()
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: [:],
                defaultID: AudioDeviceID(1)
            )
        )
        do {
            let stream = try await provider.start(deviceID: nil)
            var iterator = stream.makeAsyncIterator()
            _ = iterator
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let stopsAfterTermination = await session.stopCount()
        XCTAssertEqual(stopsAfterTermination, 1)
        await provider.stop()
        let stopsAfterExplicitStop = await session.stopCount()
        XCTAssertEqual(stopsAfterExplicitStop, 1)
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        samples.enumerated().forEach { index, value in
            channel[index] = value
        }
        return buffer
    }
}

private enum CoreAudioSessionTestError: Error, Equatable, Sendable {
    case startFailed
}

private enum FakeAUHALTestError: Error {
    case maximumFramesReadFailed
}

private actor FakeCoreAudioMicrophoneSession:
    CoreAudioMicrophoneSessionManaging {
    private var configuredIDs: [AudioDeviceID?] = []
    private var handler:
        (@Sendable (CoreAudioMicrophoneSessionEvent) -> Void)?
    private var startError: CoreAudioSessionTestError?
    private var pauses = 0
    private var resumes = 0
    private var stops = 0

    func configure(
        deviceID: AudioDeviceID?,
        eventHandler:
            @escaping @Sendable (CoreAudioMicrophoneSessionEvent) -> Void
    ) async throws {
        configuredIDs.append(deviceID)
        handler = eventHandler
    }

    func start() async throws {
        if let startError {
            throw startError
        }
    }

    func pause() async {
        pauses += 1
    }

    func resume() async throws {
        resumes += 1
    }

    func stop() async {
        stops += 1
        handler = nil
    }

    func emit(_ event: CoreAudioMicrophoneSessionEvent) {
        handler?(event)
    }

    func setStartError(_ error: CoreAudioSessionTestError?) {
        startError = error
    }

    func configuredDeviceIDs() -> [AudioDeviceID?] {
        configuredIDs
    }

    func pauseCount() -> Int {
        pauses
    }

    func resumeCount() -> Int {
        resumes
    }

    func stopCount() -> Int {
        stops
    }
}

private struct StaticCoreAudioDeviceIDResolver:
    CoreAudioDeviceIDResolving {
    let idsByUID: [String: AudioDeviceID]
    let defaultID: AudioDeviceID

    func resolve(deviceID: String?) throws -> AudioDeviceID {
        if let deviceID {
            return idsByUID[deviceID] ?? defaultID
        }
        return defaultID
    }
}

private final class FakeCoreAudioMicrophoneAudioUnitAPI:
    CoreAudioMicrophoneAudioUnitAPI,
    @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case enableIO(Bool, UInt32, UInt32)
        case setCurrentDevice(AudioDeviceID)
        case readInputStreamFormat(UInt32, UInt32)
        case setClientInputFormat(Double, UInt32)
        case readMaximumFramesPerSlice
        case setInputCallback(UInt32, UInt32, UInt32)
        case initialize
        case start
        case stop
        case uninitialize
        case dispose
        case render(bus: UInt32, frames: UInt32)
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var storedCallback: AURenderCallbackStruct?
    private var renderHandler:
        (@Sendable (
            UInt32,
            UInt32,
            UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus)?
    private let inputFormat: AudioStreamBasicDescription
    private let maximumFramesPerSlice: UInt32
    private var renderStatus: OSStatus
    private var maximumFramesPerSliceError: Error?
    private let fakeUnit: AudioUnit

    init(
        sampleRate: Double = 48_000,
        channelCount: UInt32 = 1,
        maximumFramesPerSlice: UInt32 = 8_192,
        renderStatus: OSStatus = noErr
    ) {
        inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.renderStatus = renderStatus
        fakeUnit = AudioUnit(bitPattern: 0x1_234)!
    }

    func makeHALOutputUnit() throws -> AudioUnit {
        fakeUnit
    }

    func enableIO(
        _ enabled: Bool,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        unit: AudioUnit
    ) throws {
        record(.enableIO(enabled, scope, element))
    }

    func setCurrentDevice(
        _ deviceID: AudioDeviceID,
        unit: AudioUnit
    ) throws {
        record(.setCurrentDevice(deviceID))
    }

    func getInputStreamFormat(
        unit: AudioUnit
    ) throws -> AudioStreamBasicDescription {
        record(
            .readInputStreamFormat(
                kAudioUnitScope_Input,
                1
            )
        )
        return inputFormat
    }

    func setClientInputFormat(
        _ format: AudioStreamBasicDescription,
        unit: AudioUnit
    ) throws {
        record(
            .setClientInputFormat(
                format.mSampleRate,
                format.mChannelsPerFrame
            )
        )
    }

    func getMaximumFramesPerSlice(
        unit: AudioUnit
    ) throws -> UInt32 {
        lock.lock()
        let error = maximumFramesPerSliceError
        lock.unlock()
        if let error {
            throw error
        }
        record(.readMaximumFramesPerSlice)
        return maximumFramesPerSlice
    }

    func setMaximumFramesPerSliceError(_ error: Error?) {
        lock.lock()
        maximumFramesPerSliceError = error
        lock.unlock()
    }

    func setInputCallback(
        _ callback: AURenderCallbackStruct,
        unit: AudioUnit
    ) throws {
        record(
            .setInputCallback(
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0
            )
        )
        lock.lock()
        storedCallback = callback
        lock.unlock()
    }

    func initialize(unit: AudioUnit) throws {
        record(.initialize)
    }

    func start(unit: AudioUnit) throws {
        record(.start)
    }

    func stop(unit: AudioUnit) {
        record(.stop)
    }

    func uninitialize(unit: AudioUnit) {
        record(.uninitialize)
    }

    func dispose(unit: AudioUnit) {
        record(.dispose)
    }

    func render(
        unit: AudioUnit,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        record(.render(bus: bus, frames: frames))
        if let renderHandler {
            return renderHandler(bus, frames, data)
        }
        return renderStatus
    }

    func calls() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func capturedInputCallback() -> AURenderCallbackStruct? {
        lock.lock()
        defer { lock.unlock() }
        return storedCallback
    }

    func setRenderHandler(
        _ handler: @escaping @Sendable (
            UInt32,
            UInt32,
            UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus
    ) {
        lock.lock()
        renderHandler = handler
        lock.unlock()
    }

    private func record(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

private enum CoreAudioMicrophoneTestHelper {
    static func invokeCapturedCallback(
        api: FakeCoreAudioMicrophoneAudioUnitAPI,
        frames: UInt32 = 480,
        bus: UInt32 = 1,
        ioData: UnsafeMutablePointer<AudioBufferList>? = nil
    ) -> OSStatus {
        guard let callback = api.capturedInputCallback(),
              let proc = callback.inputProc,
              let refCon = callback.inputProcRefCon else {
            return OSStatus(-999)
        }
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        return proc(
            refCon,
            &flags,
            &timestamp,
            bus,
            frames,
            ioData
        )
    }
}

final class CoreAudioMicrophoneSPSCRingTests: XCTestCase {
    func testCoreAudioRingPreservesFIFOOrdering() throws {
        let ring = try makeRing(capacity: 4)
        for sampleTime in [0, 480, 960, 1440] {
            let slot = try XCTUnwrap(
                ring.acquireWritableSlot()
            )
            slot.sampleTime = AVAudioFramePosition(sampleTime)
            ring.publishWrittenSlot()
        }

        var readSampleTimes: [AVAudioFramePosition] = []
        while let slot = ring.acquireReadableSlot() {
            readSampleTimes.append(slot.sampleTime)
            ring.releaseReadSlot()
        }

        XCTAssertEqual(
            readSampleTimes,
            [0, 480, 960, 1440]
        )
    }

    func testCoreAudioRingDoesNotReuseSlotBeforeConsumerRelease()
        throws {
        let ring = try makeRing(capacity: 4)
        for _ in 0..<4 {
            let slot = try XCTUnwrap(
                ring.acquireWritableSlot()
            )
            ring.publishWrittenSlot()
        }

        XCTAssertNil(ring.acquireWritableSlot())

        let readable = try XCTUnwrap(ring.acquireReadableSlot())
        _ = readable
        XCTAssertNil(ring.acquireWritableSlot())

        ring.releaseReadSlot()
        XCTAssertNotNil(ring.acquireWritableSlot())
    }

    private func makeRing(
        capacity: Int
    ) throws -> CoreAudioMicrophoneSPSCRing {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let slots = try (0...capacity).map { _ in
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: 480
                )
            )
            return CoreAudioMicrophoneSlot(buffer: buffer)
        }
        return CoreAudioMicrophoneSPSCRing(slots: slots)
    }
}

final class CoreAudioMicrophoneLiveSessionTests: XCTestCase {
    func testLiveSessionConfiguresAUHALInputUsingInputCallbackProperty()
        async throws {
        let api = FakeCoreAudioMicrophoneAudioUnitAPI()
        let session = LiveCoreAudioMicrophoneSession(api: api)

        try await session.configure(
            deviceID: AudioDeviceID(42),
            eventHandler: { _ in }
        )
        defer {
            Task {
                await session.stop()
            }
        }

        let calls = api.calls()
        XCTAssertTrue(
            calls.contains(
                .enableIO(true, kAudioUnitScope_Input, 1)
            )
        )
        XCTAssertTrue(
            calls.contains(
                .enableIO(false, kAudioUnitScope_Output, 0)
            )
        )
        XCTAssertTrue(
            calls.contains(.setCurrentDevice(AudioDeviceID(42)))
        )
        XCTAssertTrue(
            calls.contains(
                .readInputStreamFormat(
                    kAudioUnitScope_Input,
                    1
                )
            )
        )
        XCTAssertTrue(
            calls.contains(.setClientInputFormat(48_000, 1))
        )
        XCTAssertTrue(
            calls.contains(.readMaximumFramesPerSlice)
        )
        XCTAssertTrue(
            calls.contains(
                .setInputCallback(
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0
                )
            )
        )
        XCTAssertTrue(calls.contains(.initialize))
        XCTAssertFalse(
            calls.contains {
                if case .setInputCallback(
                    kAudioUnitProperty_SetRenderCallback,
                    _,
                    _
                ) = $0 {
                    return true
                }
                return false
            }
        )
    }

    func testLiveSessionInputCallbackRendersIntoOwnedBufferWhenIODataIsNil()
        async throws {
        let api = FakeCoreAudioMicrophoneAudioUnitAPI(
            sampleRate: 48_000,
            channelCount: 1
        )
        api.setRenderHandler { _, frames, data in
            let bufferList = data.pointee
            XCTAssertEqual(
                Int(bufferList.mNumberBuffers),
                1
            )
            guard let mData = bufferList.mBuffers.mData else {
                return OSStatus(-1)
            }
            let floats = mData.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                floats[index] = Float(index) / 100
            }
            return noErr
        }
        let session = LiveCoreAudioMicrophoneSession(api: api)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let stream = try await provider.start(deviceID: "mic")

        let status = CoreAudioMicrophoneTestHelper
            .invokeCapturedCallback(
                api: api,
                frames: 480,
                bus: 1,
                ioData: nil
            )
        XCTAssertEqual(status, noErr)

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let sample = try XCTUnwrap(next)
        XCTAssertEqual(sample.buffer.frameLength, 480)
        XCTAssertEqual(sample.sampleRate, 48_000)
        let floats = try XCTUnwrap(
            sample.buffer.floatChannelData?.pointee
        )
        XCTAssertEqual(floats[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(floats[1], 0.01, accuracy: 0.000_1)
        XCTAssertEqual(floats[479], 4.79, accuracy: 0.000_1)
        await provider.stop()
    }

    func testLiveSessionPropagatesAudioUnitRenderFailure() async throws {
        let testStatus = OSStatus(-5555)
        let api = FakeCoreAudioMicrophoneAudioUnitAPI(
            renderStatus: testStatus
        )
        let session = LiveCoreAudioMicrophoneSession(api: api)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let stream = try await provider.start(deviceID: "mic")

        let status = CoreAudioMicrophoneTestHelper
            .invokeCapturedCallback(
                api: api,
                frames: 480
            )
        XCTAssertEqual(status, testStatus)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected render failure")
        } catch {
            XCTAssertEqual(
                error as? CoreAudioMicrophoneError,
                .renderFailed(testStatus)
            )
        }
        await provider.stop()
    }

    func testLiveSessionOverflowRendersIntoScratchAndDoesNotFail()
        async throws {
        let api = FakeCoreAudioMicrophoneAudioUnitAPI(
            sampleRate: 48_000,
            channelCount: 1
        )
        api.setRenderHandler { _, frames, data in
            let bufferList = data.pointee
            guard let mData = bufferList.mBuffers.mData else {
                return OSStatus(-1)
            }
            let floats = mData.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                floats[index] = 0
            }
            return noErr
        }
        let session = LiveCoreAudioMicrophoneSession(
            api: api,
            ringSlotCount: 5
        )
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let stream = try await provider.start(deviceID: "mic")

        session.setDrainSuspendedForTesting(true)
        for _ in 0..<4 {
            XCTAssertEqual(
                CoreAudioMicrophoneTestHelper
                    .invokeCapturedCallback(
                        api: api,
                        frames: 480
                    ),
                noErr
            )
        }
        XCTAssertEqual(
            CoreAudioMicrophoneTestHelper
                .invokeCapturedCallback(
                    api: api,
                    frames: 480
                ),
            noErr
        )
        XCTAssertEqual(session.testDroppedInputFrameCount, 480)

        session.setDrainSuspendedForTesting(false)

        var iterator = stream.makeAsyncIterator()
        for _ in 0..<4 {
            let next = try await iterator.next()
            XCTAssertNotNil(next)
        }

        for _ in 0..<100 {
            if session.testDroppedInputFrameCount == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.testDroppedInputFrameCount, 0)

        XCTAssertEqual(
            CoreAudioMicrophoneTestHelper
                .invokeCapturedCallback(
                    api: api,
                    frames: 480
                ),
            noErr
        )
        let finalNext = try await iterator.next()
        XCTAssertNotNil(finalNext)
        await provider.stop()
    }

    func testLiveSessionUsesConservativeCapacityWhenMaximumFramesPropertyFails()
        async throws {
        let api = FakeCoreAudioMicrophoneAudioUnitAPI(
            sampleRate: 48_000,
            channelCount: 1
        )
        api.setMaximumFramesPerSliceError(
            FakeAUHALTestError.maximumFramesReadFailed
        )
        api.setRenderHandler { _, frames, data in
            let bufferList = data.pointee
            guard let mData = bufferList.mBuffers.mData else {
                return OSStatus(-1)
            }
            let floats = mData.assumingMemoryBound(to: Float.self)
            for index in 0..<Int(frames) {
                floats[index] = 0.25
            }
            return noErr
        }
        let session = LiveCoreAudioMicrophoneSession(api: api)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let stream = try await provider.start(deviceID: "mic")

        let status = CoreAudioMicrophoneTestHelper
            .invokeCapturedCallback(
                api: api,
                frames: 8192
            )
        XCTAssertEqual(status, noErr)

        var iterator = stream.makeAsyncIterator()
        let sample = try await iterator.next()
        XCTAssertEqual(sample?.buffer.frameLength, 8192)
        await provider.stop()
    }

    func testLiveSessionDeepCopiesMultipleChannelsWithoutReuse()
        async throws {
        let api = FakeCoreAudioMicrophoneAudioUnitAPI(
            sampleRate: 48_000,
            channelCount: 2
        )
        api.setRenderHandler { _, frames, data in
            let bufferList = UnsafeMutableAudioBufferListPointer(data)
            XCTAssertEqual(
                bufferList.count,
                2
            )
            for channel in 0..<2 {
                guard let mData =
                    bufferList[channel].mData else {
                    return OSStatus(-1)
                }
                let floats = mData.assumingMemoryBound(
                    to: Float.self
                )
                for index in 0..<Int(frames) {
                    floats[index] =
                        channel == 0
                        ? Float(index) / 100
                        : Float(index) / 100 + 1
                }
            }
            return noErr
        }
        let session = LiveCoreAudioMicrophoneSession(api: api)
        let provider = CoreAudioMicrophoneSampleProvider(
            session: session,
            resolver: StaticCoreAudioDeviceIDResolver(
                idsByUID: ["mic": AudioDeviceID(42)],
                defaultID: AudioDeviceID(42)
            )
        )
        let stream = try await provider.start(deviceID: "mic")

        XCTAssertEqual(
            CoreAudioMicrophoneTestHelper
                .invokeCapturedCallback(
                    api: api,
                    frames: 480
                ),
            noErr
        )

        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let firstSample = try XCTUnwrap(next)
        XCTAssertEqual(firstSample.buffer.format.channelCount, 2)
        XCTAssertEqual(firstSample.buffer.frameLength, 480)
        let firstChannels = try XCTUnwrap(
            firstSample.buffer.floatChannelData
        )
        let firstChannelZero = try XCTUnwrap(
            firstChannels[0]
        )
        let firstChannelOne = try XCTUnwrap(
            firstChannels[1]
        )
        XCTAssertEqual(
            firstChannelZero[0],
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            firstChannelZero[1],
            0.01,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            firstChannelOne[0],
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            firstChannelOne[1],
            1.01,
            accuracy: 0.000_1
        )

        XCTAssertEqual(
            CoreAudioMicrophoneTestHelper
                .invokeCapturedCallback(
                    api: api,
                    frames: 480
                ),
            noErr
        )
        let later = try await iterator.next()
        XCTAssertNotNil(later)

        XCTAssertEqual(
            firstChannelZero[0],
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            firstChannelOne[1],
            1.01,
            accuracy: 0.000_1
        )
        await provider.stop()
    }
}
