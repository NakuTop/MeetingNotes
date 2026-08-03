import AVFoundation
import XCTest
@testable import MeetingNotes

final class MicrophoneCaptureSourceTests: XCTestCase {
    func testSelectedDeviceIDReachesProviderAndSamplesBecomeMasterPackets() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: "preferred-microphone",
            sampleProvider: provider
        )
        let stream = try await source.start()
        let buffer = try makeMicrophoneBuffer(samples: [0.25, -0.5, 0.75])

        await provider.yield(
            MicrophoneSample(
                buffer: buffer,
                sampleTime: 4_800,
                sampleRate: 48_000
            )
        )

        var iterator = stream.makeAsyncIterator()
        let nextPacket = try await iterator.next()
        let packet = try XCTUnwrap(nextPacket)
        let startedDeviceIDs = await provider.startedDeviceIDs()
        XCTAssertEqual(startedDeviceIDs, ["preferred-microphone"])
        XCTAssertFalse(packet.master.samples.isEmpty)
        XCTAssertTrue(packet.master.samples.contains { abs($0) > 0.01 })
        XCTAssertTrue(packet.sourceFrames.isEmpty)
        await source.stop()
    }

    func testStartFailureIsPropagatedAndSourceCanBeStartedAgain() async throws {
        let provider = FakeMicrophoneSampleProvider()
        await provider.setStartError(MicrophoneSourceTestError.startFailed)
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider
        )

        do {
            _ = try await source.start()
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(error as? MicrophoneSourceTestError, .startFailed)
        }

        await provider.setStartError(nil)
        _ = try await source.start()
        let startedDeviceIDs = await provider.startedDeviceIDs()
        XCTAssertEqual(startedDeviceIDs, [nil, nil])
        await source.stop()
    }

    func testInvalidSampleFormatFinishesStreamWithConverterError() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider
        )
        let stream = try await source.start()
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let emptyBuffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        )

        await provider.yield(
            MicrophoneSample(
                buffer: emptyBuffer,
                sampleTime: 0,
                sampleRate: 48_000
            )
        )

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected invalid input format")
        } catch {
            XCTAssertEqual(error as? PCMConverterError, .invalidInputFormat)
        }
        let stopCount = await provider.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testPauseResumeForwardToProviderAndAreIdempotent() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider
        )
        _ = try await source.start()

        try await source.pause()
        try await source.pause()
        try await source.resume()
        try await source.resume()

        let pauseCount = await provider.pauseCount()
        let resumeCount = await provider.resumeCount()
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)
        await source.stop()
    }

    func testStopIsIdempotentAndFinishesStreamExactlyOnce() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider
        )
        let stream = try await source.start()

        await source.stop()
        await source.stop()

        let stopCount = await provider.stopCount()
        XCTAssertEqual(stopCount, 1)
        var iterator = stream.makeAsyncIterator()
        let firstAfterStop = try await iterator.next()
        let secondAfterStop = try await iterator.next()
        XCTAssertNil(firstAfterStop)
        XCTAssertNil(secondAfterStop)
    }

    func testStopDrainsSamplesAcceptedBeforeShutdown() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let gate = MicrophoneSourceProcessingGate()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider,
            beforeProcessingSample: {
                await gate.enterAndWait()
            }
        )
        let stream = try await source.start()
        let sample = MicrophoneSample(
            buffer: try makeMicrophoneBuffer(
                samples: Array(repeating: 0.4, count: 480)
            ),
            sampleTime: 0,
            sampleRate: 48_000
        )
        await provider.yield(sample)
        await gate.waitUntilEntered()

        let stopping = Task {
            await source.stop()
        }
        await Task.yield()
        await gate.open()
        await stopping.value

        var iterator = stream.makeAsyncIterator()
        let packet = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertNotNil(packet)
        XCTAssertNil(end)
    }

    func testProviderStreamFailureStopsProviderAndPropagatesOnce() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider
        )
        let stream = try await source.start()

        await provider.finish(throwing: MicrophoneSourceTestError.streamFailed)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected stream failure")
        } catch {
            XCTAssertEqual(error as? MicrophoneSourceTestError, .streamFailed)
        }
        let stopCount = await provider.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testSourceBacklogOverflowTerminatesWithoutWaitingForBlockedDrain() async throws {
        let provider = FakeMicrophoneSampleProvider()
        let gate = MicrophoneSourceProcessingGate()
        let source = MicrophoneCaptureSource(
            selectedDeviceID: nil,
            sampleProvider: provider,
            drainCapacity: 1,
            beforeProcessingSample: {
                await gate.enterAndWait()
            }
        )
        let stream = try await source.start()
        let buffer = try makeMicrophoneBuffer(samples: [0.2, 0.3])
        let sample = MicrophoneSample(
            buffer: buffer,
            sampleTime: 0,
            sampleRate: 48_000
        )

        await provider.yield(sample)
        await gate.waitUntilEntered()
        await provider.yield(sample)

        let terminated = expectation(description: "stream terminated")
        let result = MicrophoneOverflowResult()
        Task {
            var iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
            } catch {
                await result.set(error)
            }
            terminated.fulfill()
        }
        await fulfillment(of: [terminated], timeout: 1)
        let overflowError = await result.error()
        XCTAssertEqual(
            overflowError as? MicrophoneCaptureError,
            .backlogCapacityExceeded
        )

        await gate.open()
        await source.stop()
    }

    func testWrapsOfflineFrameAsMasterWithoutDuplicateSourceTrack() {
        let frame = CapturedAudioFrame(
            timestamp: 0.25,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: [0.1, -0.2]
        )

        let packet = MicrophoneCaptureSource.packet(from: frame)

        XCTAssertEqual(packet.master, frame)
        XCTAssertTrue(packet.sourceFrames.isEmpty)
        requireSendable(packet)
    }

    func testFinishAndWaitDrainsAcceptedBuffersInStrictOrder() async {
        let gate = MicrophoneDrainTestGate()
        let recorder = MicrophoneDrainRecorder()
        let completion = MicrophoneDrainCompletion()
        let drain = MicrophoneCaptureDrainQueue<Int>(capacity: 3) { value in
            await recorder.markStarted(value)
            if value == 1 {
                await gate.wait()
            }
            await recorder.markCompleted(value)
        }

        XCTAssertTrue(drain.enqueue(1))
        XCTAssertTrue(drain.enqueue(2))
        XCTAssertTrue(drain.enqueue(3))
        await recorder.waitUntilStarted(1)

        let stopping = Task {
            await drain.finishAndWait()
            await completion.markCompleted()
        }
        await Task.yield()

        let completedBeforeOpening = await completion.isCompleted()
        XCTAssertFalse(completedBeforeOpening)
        await gate.open()
        await stopping.value

        let completedValues = await recorder.completedValues()
        XCTAssertEqual(completedValues, [1, 2, 3])
        XCTAssertFalse(drain.enqueue(4))
    }

    func testOverflowClosesInputAndDrainsAcceptedBuffersWithoutDeadlock() async {
        let gate = MicrophoneDrainTestGate()
        let recorder = MicrophoneDrainRecorder()
        let completion = MicrophoneDrainCompletion()
        let overflow = MicrophoneDrainOverflowRecorder()
        let drain = MicrophoneCaptureDrainQueue<Int>(
            capacity: 3,
            onOverflow: {
                overflow.record()
            },
            handler: { value in
                await recorder.markStarted(value)
                if value == 1 {
                    await gate.wait()
                }
                await recorder.markCompleted(value)
            }
        )

        XCTAssertTrue(drain.enqueue(1))
        await recorder.waitUntilStarted(1)
        XCTAssertTrue(drain.enqueue(2))
        XCTAssertTrue(drain.enqueue(3))
        XCTAssertFalse(drain.enqueue(4))
        XCTAssertFalse(drain.enqueue(5))

        let draining = Task {
            await drain.waitUntilDrained()
            await completion.markCompleted()
        }
        await Task.yield()
        let completedWhileBlocked = await completion.isCompleted()
        XCTAssertFalse(completedWhileBlocked)

        await gate.open()
        await draining.value

        let completedValues = await recorder.completedValues()
        let overflowCount = overflow.count()
        XCTAssertEqual(completedValues, [1, 2, 3])
        XCTAssertEqual(overflowCount, 1)
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }

    private func makeMicrophoneBuffer(
        samples: [Float],
        sampleRate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
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
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        samples.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memcpy(channel, baseAddress, bytes.count)
            }
        }
        return buffer
    }
}

private enum MicrophoneSourceTestError: Error, Equatable, Sendable {
    case startFailed
    case streamFailed
}

private actor FakeMicrophoneSampleProvider: MicrophoneSampleProviding {
    private var starts: [String?] = []
    private var startError: MicrophoneSourceTestError?
    private var pauses = 0
    private var resumes = 0
    private var stops = 0
    private var continuation:
        AsyncThrowingStream<MicrophoneSample, Error>.Continuation?

    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error> {
        starts.append(deviceID)
        if let startError {
            throw startError
        }
        let pair = AsyncThrowingStream<MicrophoneSample, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func pause() async throws {
        pauses += 1
    }

    func resume() async throws {
        resumes += 1
    }

    func stop() async {
        stops += 1
        continuation?.finish()
        continuation = nil
    }

    func setStartError(_ error: MicrophoneSourceTestError?) {
        startError = error
    }

    func yield(_ sample: MicrophoneSample) {
        continuation?.yield(sample)
    }

    func finish(throwing error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func startedDeviceIDs() -> [String?] {
        starts
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

private actor MicrophoneSourceProcessingGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor MicrophoneOverflowResult {
    private var capturedError: Error?

    func set(_ error: Error) {
        capturedError = error
    }

    func error() -> Error? {
        capturedError
    }
}

private actor MicrophoneDrainTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MicrophoneDrainRecorder {
    private var started: Set<Int> = []
    private var completed: [Int] = []
    private var startedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted(_ value: Int) {
        started.insert(value)
        startedWaiters.removeValue(forKey: value)?.forEach { $0.resume() }
    }

    func waitUntilStarted(_ value: Int) async {
        guard !started.contains(value) else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[value, default: []].append(continuation)
        }
    }

    func markCompleted(_ value: Int) {
        completed.append(value)
    }

    func completedValues() -> [Int] {
        completed
    }
}

private actor MicrophoneDrainCompletion {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class MicrophoneDrainOverflowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
