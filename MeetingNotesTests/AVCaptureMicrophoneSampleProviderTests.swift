import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingNotes

final class AVCaptureMicrophoneSampleProviderTests: XCTestCase {
    func testSelectedDeviceIsConfiguredAndDeliveredSampleOwnsItsStorage() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let source = try makeAudioSampleBuffer(samples: [0.2, -0.4, 0.6])

        let stream = try await provider.start(deviceID: "external-mic")
        await session.emit(.sampleBuffer(source.sampleBuffer))
        try source.overwriteSamples(with: [0, 0, 0])

        var iterator = stream.makeAsyncIterator()
        let nextSample = try await iterator.next()
        let sample = try XCTUnwrap(nextSample)
        let configuredDeviceIDs = await session.configuredDeviceIDs()
        XCTAssertEqual(configuredDeviceIDs, ["external-mic"])
        XCTAssertEqual(sample.sampleTime, 4_800)
        XCTAssertEqual(sample.sampleRate, 48_000)
        XCTAssertEqual(
            Array(
                UnsafeBufferPointer(
                    start: try XCTUnwrap(
                        sample.buffer.floatChannelData?.pointee
                    ),
                    count: Int(sample.buffer.frameLength)
                )
            ),
            [0.2, -0.4, 0.6]
        )
        await provider.stop()
    }

    func testStartFailureStopsConfiguredSessionAndCanRetry() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        await session.setStartError(MicrophoneProviderTestError.startFailed)
        let provider = AVCaptureMicrophoneSampleProvider(session: session)

        do {
            _ = try await provider.start(deviceID: nil)
            XCTFail("Expected start failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneProviderTestError,
                .startFailed
            )
        }
        let failedStartStopCount = await session.stopCount()
        XCTAssertEqual(failedStartStopCount, 1)

        await session.setStartError(nil)
        let stream = try await provider.start(deviceID: nil)
        await provider.stop()
        withExtendedLifetime(stream) {}
        let finalStopCount = await session.stopCount()
        XCTAssertEqual(finalStopCount, 2)
    }

    func testPauseResumeAndStopAreForwardedIdempotently() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let stream = try await provider.start(deviceID: nil)

        try await provider.pause()
        try await provider.pause()
        try await provider.resume()
        try await provider.resume()
        await provider.stop()
        await provider.stop()
        withExtendedLifetime(stream) {}

        let pauseCount = await session.pauseCount()
        let resumeCount = await session.resumeCount()
        let stopCount = await session.stopCount()
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testLatePauseFromStoppedRunCannotMutateRestartedRun()
        async throws {
        let session = FakeAVCaptureMicrophoneSession(
            blockedOperation: .pause
        )
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let staleStream = try await provider.start(deviceID: "A")
        let stalePause = Task {
            try await provider.pause()
        }
        await session.waitUntilPauseEntered()

        await provider.stop()
        let currentStream = try await provider.start(deviceID: "B")
        await session.releasePause()
        do {
            try await stalePause.value
            XCTFail("Expected stale pause cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        try await provider.pause()
        let pauses = await session.pauseCount()
        let resumes = await session.resumeCount()
        let stopsBeforeFinalStop = await session.stopCount()
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(stopsBeforeFinalStop, 1)

        await provider.stop()
        withExtendedLifetime((staleStream, currentStream)) {}
    }

    func testLateResumeFromStoppedRunCannotMutateRestartedRun()
        async throws {
        let session = FakeAVCaptureMicrophoneSession(
            blockedOperation: .resume
        )
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let staleStream = try await provider.start(deviceID: "A")
        try await provider.pause()
        let staleResume = Task {
            try await provider.resume()
        }
        await session.waitUntilResumeEntered()

        await provider.stop()
        let currentStream = try await provider.start(deviceID: "B")
        try await provider.pause()
        await session.releaseResume()
        do {
            try await staleResume.value
            XCTFail("Expected stale resume cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        try await provider.resume()
        let pauses = await session.pauseCount()
        let resumes = await session.resumeCount()
        let stopsBeforeFinalStop = await session.stopCount()
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(resumes, 2)
        XCTAssertEqual(stopsBeforeFinalStop, 1)

        await provider.stop()
        withExtendedLifetime((staleStream, currentStream)) {}
    }

    func testInvalidSampleFormatFinishesOnceAndStopsSession() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let stream = try await provider.start(deviceID: nil)
        let invalid = try makeInvalidSampleBuffer()

        await session.emit(.sampleBuffer(invalid))
        await session.emit(.sampleBuffer(invalid))

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected invalid sample error")
        } catch {
            XCTAssertEqual(
                error as? AudioSampleBufferDecoderError,
                .invalidSample
            )
        }
        await session.waitUntilStopCount(1)
        let stopCount = await session.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRuntimeFailureFinishesOnceAndStopsSession() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let stream = try await provider.start(deviceID: nil)

        await session.emit(.failure(MicrophoneProviderTestError.runtimeFailed))
        await session.emit(.failure(MicrophoneProviderTestError.runtimeFailed))

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected runtime failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneProviderTestError,
                .runtimeFailed
            )
        }
        await session.waitUntilStopCount(1)
        let stopCount = await session.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testProviderBufferOverflowFailsAndStopsSessionExactlyOnce() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(
            session: session,
            bufferCapacity: 1
        )
        let first = try makeAudioSampleBuffer(samples: [0.1, 0.2])
        let dropped = try makeAudioSampleBuffer(samples: [0.3, 0.4])
        let stream = try await provider.start(deviceID: nil)

        await session.emit(.sampleBuffer(first.sampleBuffer))
        await session.emit(.sampleBuffer(dropped.sampleBuffer))
        await session.emit(.sampleBuffer(dropped.sampleBuffer))

        var iterator = stream.makeAsyncIterator()
        let firstDeliveredSample = try await iterator.next()
        XCTAssertNotNil(firstDeliveredSample)
        do {
            _ = try await iterator.next()
            XCTFail("Expected provider backlog failure")
        } catch {
            XCTAssertEqual(
                error as? MicrophoneCaptureError,
                .backlogCapacityExceeded
            )
        }
        await session.waitUntilStopCount(1)
        await provider.stop()
        let stopCount = await session.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testCancellingConsumerStopsSessionExactlyOnce() async throws {
        let session = FakeAVCaptureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let stream = try await provider.start(deviceID: nil)
        let stopped = expectation(description: "session stopped")
        let stopWaiter = Task {
            await session.waitUntilStopCount(1)
            stopped.fulfill()
        }
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the behavior under test.
            }
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        await consumer.value
        await provider.stop()
        await stopWaiter.value

        let stopCount = await session.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testStopDuringConfigureCancelsStaleStartWithoutStoppingReplacement()
        async throws {
        let session = SuspendedFirstConfigureMicrophoneSession()
        let provider = AVCaptureMicrophoneSampleProvider(session: session)
        let staleStart = Task {
            try await provider.start(deviceID: "disconnected-mic")
        }
        await session.waitUntilFirstConfigureStarts()

        await provider.stop()
        let replacementStream = try await provider.start(
            deviceID: "replacement-mic"
        )
        await session.resumeFirstConfigure()

        do {
            _ = try await staleStart.value
            XCTFail("Expected the stale start to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected stale-start error: \(error)")
        }
        let startCountBeforeFinalStop = await session.startCount()
        let stopCountBeforeFinalStop = await session.stopCount()
        XCTAssertEqual(startCountBeforeFinalStop, 1)
        XCTAssertEqual(stopCountBeforeFinalStop, 1)

        await provider.stop()
        withExtendedLifetime(replacementStream) {}
        let finalStopCount = await session.stopCount()
        XCTAssertEqual(finalStopCount, 2)
    }

    private func makeAudioSampleBuffer(
        samples: [Float]
    ) throws -> MutableAudioSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let unwrappedBlockBuffer = try XCTUnwrap(blockBuffer)
        try samples.withUnsafeBytes { bytes in
            XCTAssertEqual(
                CMBlockBufferReplaceDataBytes(
                    with: try XCTUnwrap(bytes.baseAddress),
                    blockBuffer: unwrappedBlockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                ),
                kCMBlockBufferNoErr
            )
        }
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: unwrappedBlockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: samples.count,
                presentationTimeStamp: CMTime(
                    value: 4_800,
                    timescale: 48_000
                ),
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return MutableAudioSampleBuffer(
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            blockBuffer: unwrappedBlockBuffer
        )
    }

    private func makeInvalidSampleBuffer() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: nil,
                sampleCount: 0,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

private struct MutableAudioSampleBuffer {
    let sampleBuffer: CMSampleBuffer
    let blockBuffer: CMBlockBuffer

    func overwriteSamples(with samples: [Float]) throws {
        try samples.withUnsafeBytes { bytes in
            let address = try XCTUnwrap(bytes.baseAddress)
            XCTAssertEqual(
                CMBlockBufferReplaceDataBytes(
                    with: address,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: bytes.count
                ),
                kCMBlockBufferNoErr
            )
        }
    }
}

private enum MicrophoneProviderTestError: Error, Equatable, Sendable {
    case startFailed
    case runtimeFailed
}

private actor FakeAVCaptureMicrophoneSession:
    AVCaptureMicrophoneSessionManaging {
    enum BlockedOperation: Sendable {
        case pause
        case resume
    }

    private let blockedOperation: BlockedOperation?
    private var configuredIDs: [String?] = []
    private var handler:
        (@Sendable (AVCaptureMicrophoneSessionEvent) -> Void)?
    private var startError: MicrophoneProviderTestError?
    private var pauses = 0
    private var resumes = 0
    private var stops = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseEntered = false
    private var resumeEntered = false
    private var pauseEnteredWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var resumeEnteredWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var pauseReleaseContinuation:
        CheckedContinuation<Void, Never>?
    private var resumeReleaseContinuation:
        CheckedContinuation<Void, Never>?

    init(blockedOperation: BlockedOperation? = nil) {
        self.blockedOperation = blockedOperation
    }

    func configure(
        deviceID: String?,
        eventHandler:
            @escaping @Sendable (AVCaptureMicrophoneSessionEvent) -> Void
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
        guard blockedOperation == .pause,
              pauses == 1 else { return }
        pauseEntered = true
        let waiters = pauseEnteredWaiters
        pauseEnteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            pauseReleaseContinuation = continuation
        }
    }

    func resume() async throws {
        resumes += 1
        guard blockedOperation == .resume,
              resumes == 1 else { return }
        resumeEntered = true
        let waiters = resumeEnteredWaiters
        resumeEnteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeReleaseContinuation = continuation
        }
    }

    func stop() async {
        stops += 1
        handler = nil
        if stops > 0 {
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func emit(_ event: AVCaptureMicrophoneSessionEvent) {
        handler?(event)
    }

    func setStartError(_ error: MicrophoneProviderTestError?) {
        startError = error
    }

    func configuredDeviceIDs() -> [String?] {
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

    func waitUntilStopCount(_ target: Int) async {
        guard stops < target else { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func waitUntilPauseEntered() async {
        guard !pauseEntered else { return }
        await withCheckedContinuation { continuation in
            pauseEnteredWaiters.append(continuation)
        }
    }

    func waitUntilResumeEntered() async {
        guard !resumeEntered else { return }
        await withCheckedContinuation { continuation in
            resumeEnteredWaiters.append(continuation)
        }
    }

    func releasePause() {
        let continuation = pauseReleaseContinuation
        pauseReleaseContinuation = nil
        continuation?.resume()
    }

    func releaseResume() {
        let continuation = resumeReleaseContinuation
        resumeReleaseContinuation = nil
        continuation?.resume()
    }
}

private actor SuspendedFirstConfigureMicrophoneSession:
    AVCaptureMicrophoneSessionManaging {
    private var configureCount = 0
    private var starts = 0
    private var stops = 0
    private var firstConfigureContinuation:
        CheckedContinuation<Void, Never>?
    private var firstConfigureWaiters:
        [CheckedContinuation<Void, Never>] = []

    func configure(
        deviceID: String?,
        eventHandler:
            @escaping @Sendable (AVCaptureMicrophoneSessionEvent) -> Void
    ) async throws {
        _ = deviceID
        _ = eventHandler
        configureCount += 1
        guard configureCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstConfigureContinuation = continuation
            let waiters = firstConfigureWaiters
            firstConfigureWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func start() async throws {
        starts += 1
    }

    func pause() async {}

    func resume() async throws {}

    func stop() async {
        stops += 1
    }

    func waitUntilFirstConfigureStarts() async {
        guard configureCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstConfigureWaiters.append(continuation)
        }
    }

    func resumeFirstConfigure() {
        firstConfigureContinuation?.resume()
        firstConfigureContinuation = nil
    }

    func startCount() -> Int {
        starts
    }

    func stopCount() -> Int {
        stops
    }
}
