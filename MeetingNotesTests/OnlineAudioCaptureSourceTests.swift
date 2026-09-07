import XCTest
@testable import MeetingNotes

final class OnlineAudioCaptureSourceTests: XCTestCase {
    func testPureAudioStartsSystemBeforeMicrophoneAndStopsBothOnce() async throws {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log)
        let mic = OnlineTestMicrophone(log: log)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: mic, systemSessionFactory: { system })
        let stream = try await source.start()
        XCTAssertEqual(log.values, ["system-start", "mic-start"])
        try await source.pause()
        try await source.resume()
        await source.stop()
        await source.stop()
        var iterator = stream.makeAsyncIterator()
        let last = try await iterator.next()
        XCTAssertNil(last)
        XCTAssertEqual(log.values.filter { $0 == "mic-stop" }.count, 1)
        XCTAssertEqual(log.values.filter { $0 == "system-stop" }.count, 1)
        XCTAssertTrue(log.values.contains("mic-pause"))
        XCTAssertTrue(log.values.contains("mic-resume"))
    }

    func testSystemFailureDoesNotStartMicrophoneOrFallBackToScreen() async {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log, failStart: true)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: OnlineTestMicrophone(log: log), systemSessionFactory: { system })
        do { _ = try await source.start(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailed) }
        XCTAssertTrue(log.values.contains("system-stop"))
        XCTAssertFalse(log.values.contains("mic-start"))
    }

    func testSystemCallbackFailureDuringStartupIsNotReportedAsUserCancellation() async {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log, failCallbackDuringStart: true)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: OnlineTestMicrophone(log: log), systemSessionFactory: { system })
        do { _ = try await source.start(); XCTFail("Expected system failure") }
        catch { XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailed) }
        XCTAssertFalse(log.values.contains("mic-start"))
        XCTAssertTrue(log.values.contains("system-stop"))
    }

    func testRealMixerReceivesBothTracksAndRejectsStartupBacklog() async throws {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log, emitBacklog: true)
        let mic = OnlineTestMicrophone(log: log)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: mic, systemSessionFactory: { system }, now: { 100 })
        let stream = try await source.start()
        let received = expectation(description: "mixed system and mic")
        received.assertForOverFulfill = false
        let outputs = OnlineTestOutputs()
        let consumer = Task {
            for try await packet in stream {
                outputs.append(packet)
                if packet.sourceFrames[.system]?.samples.contains(where: { $0 > 0 }) == true,
                   packet.sourceFrames[.microphone]?.samples.contains(where: { $0 > 0 }) == true {
                    received.fulfill()
                }
            }
        }
        for index in 0..<12 {
            system.emit(frame(index: index, value: 0.2))
            await mic.emit(frame(index: index, value: 0.1))
        }
        await fulfillment(of: [received], timeout: 2)
        await source.stop()
        try await consumer.value
        let packets = outputs.values
        XCTAssertFalse(packets.isEmpty)
        XCTAssertTrue(packets.allSatisfy { $0.master.transcriptionSampleRate == 16_000 })
        XCTAssertFalse(packets.flatMap { $0.master.samples }.contains { $0 > 0.4 })
        XCTAssertLessThan(packets.flatMap { $0.master.samples }.count, 48_000)
        XCTAssertTrue(zip(packets, packets.dropFirst()).allSatisfy { $0.master.timestamp < $1.master.timestamp })
    }

    func testRuntimeSystemFailureFinishesCallerAndCleansBothSources() async throws {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: OnlineTestMicrophone(log: log), systemSessionFactory: { system })
        let stream = try await source.start()
        system.fail()
        do {
            for try await _ in stream {}
            XCTFail("Expected system failure")
        } catch { XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailed) }
        await source.stop()
        XCTAssertTrue(log.values.contains("system-stop"))
        XCTAssertTrue(log.values.contains("mic-stop"))
    }

    func testPauseFailureTerminatesAndCleansBothSources() async throws {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log)
        let mic = OnlineTestMicrophone(log: log, failPause: true)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: mic, systemSessionFactory: { system })
        let stream = try await source.start()
        do { try await source.pause(); XCTFail("Expected pause failure") }
        catch { XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailed) }
        XCTAssertTrue(log.values.contains("system-stop"))
        XCTAssertTrue(log.values.contains("mic-stop"))
        // Explicit final cleanup also lets this regression fail safely against
        // a source that incorrectly leaves its relay suspended.
        await source.stop()
        _ = stream
    }

    func testStopCancelsPendingMicrophoneStartupBeforeAllowingRestart() async throws {
        let entered = expectation(description: "microphone startup entered")
        let cancelled = expectation(description: "pending microphone startup cancelled")
        let release = OnlineTestBarrier()
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log)
        let mic = OnlineTestMicrophone(log: log, beforeFirstStart: {
            try await withTaskCancellationHandler {
                entered.fulfill()
                await release.wait()
                try Task.checkCancellation()
            } onCancel: { cancelled.fulfill() }
        })
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: mic, systemSessionFactory: { system })
        let startup = Task { try await source.start() }
        await fulfillment(of: [entered], timeout: 2)
        let stopping = Task { await source.stop() }
        await fulfillment(of: [cancelled], timeout: 2)
        // Release is controlled, not sleep-based. The explicit cancel is also
        // safe cleanup for the old implementation when the assertion fails.
        startup.cancel()
        await release.open()
        await stopping.value
        do { _ = try await startup.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let restarted = try await source.start()
        XCTAssertEqual(log.values.filter { $0 == "mic-stop" }.count, 1)
        await source.stop()
        _ = restarted
    }

    func testResumeReanchorsSystemAndPausedMicrophoneClocksTogether() async throws {
        let log = OnlineTestLog()
        let system = OnlineTestSystem(log: log)
        let mic = OnlineTestMicrophone(log: log)
        let clock = OnlineTestClock(100)
        let source = OnlineAudioCaptureSource(microphoneCaptureSource: mic, systemSessionFactory: { system }, now: { clock.value })
        let stream = try await source.start()
        let beforePause = expectation(description: "both tracks before pause")
        let afterPause = expectation(description: "both tracks after pause")
        beforePause.assertForOverFulfill = false
        afterPause.assertForOverFulfill = false
        let output = OnlineTestOutputs()
        let consumer = Task {
            for try await packet in stream {
                output.append(packet)
                let micPeak = packet.sourceFrames[.microphone]?.samples.max() ?? 0
                let systemPeak = packet.sourceFrames[.system]?.samples.max() ?? 0
                if micPeak > 0, systemPeak > 0 {
                    if packet.master.timestamp < 1 { beforePause.fulfill() }
                    else { afterPause.fulfill() }
                }
            }
        }
        for index in 0..<12 {
            system.emit(frame(index: index, value: 0.2))
            await mic.emit(frame(index: index, value: 0.1))
        }
        await fulfillment(of: [beforePause], timeout: 2)
        try await source.pause()
        clock.set(105.24)
        try await source.resume()
        for index in 12..<24 {
            // Tap continued through the pause; AUHAL mic sampleTime did not.
            system.emit(frame(index: index + 250, value: 0.2))
            await mic.emit(frame(index: index, value: 0.1))
        }
        await fulfillment(of: [afterPause], timeout: 2)
        await source.stop()
        try await consumer.value
        let packets = output.values
        XCTAssertTrue(zip(packets, packets.dropFirst()).allSatisfy { $0.master.timestamp < $1.master.timestamp })
    }

    private func frame(index: Int, value: Float) -> CapturedAudioFrame {
        CapturedAudioFrame(timestamp: Double(index) * 0.02, sampleRate: 48_000, samples: Array(repeating: value, count: 960))
    }
}

private final class OnlineTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var values: [String] { lock.withLock { entries } }
}

private final class OnlineTestSystem: SystemAudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SystemAudioCaptureEvent) -> Void)?
    let log: OnlineTestLog
    let failStart: Bool
    let emitBacklog: Bool
    let failCallbackDuringStart: Bool
    private let startBarrier = OnlineTestBarrier()
    init(log: OnlineTestLog, failStart: Bool = false, emitBacklog: Bool = false,
         failCallbackDuringStart: Bool = false) {
        self.log = log; self.failStart = failStart; self.emitBacklog = emitBacklog
        self.failCallbackDuringStart = failCallbackDuringStart
    }
    func start(onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) async throws {
        log.append("system-start")
        lock.withLock { handler = onEvent }
        if emitBacklog {
            emit(CapturedAudioFrame(timestamp: 0, sampleRate: 48_000, samples: Array(repeating: 0.9, count: 96_000)))
        }
        if failStart { throw SystemAudioCaptureError.inputFailed }
        if failCallbackDuringStart {
            fail()
            await startBarrier.wait()
        }
    }
    func stop() async { log.append("system-stop"); await startBarrier.open() }
    func emit(_ frame: CapturedAudioFrame) { lock.withLock { handler }?(.frame(frame)) }
    func fail() { lock.withLock { handler }?(.failure(SystemAudioCaptureError.inputFailed)) }
}

private actor OnlineTestMicrophone: AudioCaptureSource {
    let log: OnlineTestLog
    let failPause: Bool
    let beforeFirstStart: @Sendable () async throws -> Void
    var startCount = 0
    var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation?
    init(log: OnlineTestLog, failPause: Bool = false,
         beforeFirstStart: @escaping @Sendable () async throws -> Void = {}) {
        self.log = log; self.failPause = failPause; self.beforeFirstStart = beforeFirstStart
    }
    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        log.append("mic-start")
        startCount += 1
        if startCount == 1 { try await beforeFirstStart() }
        let pair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func pause() async throws {
        log.append("mic-pause")
        if failPause { throw SystemAudioCaptureError.inputFailed }
    }
    func resume() async throws { log.append("mic-resume") }
    func stop() async { log.append("mic-stop"); continuation?.finish(); continuation = nil }
    func emit(_ frame: CapturedAudioFrame) { continuation?.yield(CapturedAudioPacket(master: frame, sourceFrames: [.microphone: frame])) }
}

private actor OnlineTestBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class OnlineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval) { self.time = time }
    var value: TimeInterval { lock.withLock { time } }
    func set(_ time: TimeInterval) { lock.withLock { self.time = time } }
}

private final class OnlineTestOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [CapturedAudioPacket] = []
    func append(_ packet: CapturedAudioPacket) { lock.withLock { packets.append(packet) } }
    var values: [CapturedAudioPacket] { lock.withLock { packets } }
}
