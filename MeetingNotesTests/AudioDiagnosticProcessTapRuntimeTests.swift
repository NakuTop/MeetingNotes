import Foundation
import XCTest
@testable import MeetingNotes

final class AudioDiagnosticProcessTapRuntimeTests: XCTestCase {
    func testPureAudioRuntimeMeasuresOwnTestToneAndStopsCapture() async throws {
        let capture = DiagnosticTapCaptureStub()
        let runtime = LiveAudioDiagnosticProcessTapRuntime(captureFactory: { configuration in
            XCTAssertFalse(configuration.excludesCurrentProcessAudio)
            XCTAssertFalse(configuration.capturesMicrophone)
            return capture
        })
        let session = SystemAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(), runtime: runtime
        )
        let metrics = try await session.testSignal(duration: 0.05) {
            // The callback is installed and capture is running before the tone.
            XCTAssertEqual(capture.startCount, 1)
            capture.emit(.frame(Self.toneFrame))
        }
        XCTAssertEqual(metrics.sampleCount, Self.toneFrame.samples.count)
        XCTAssertEqual(metrics.sampleRate, 48_000)
        XCTAssertEqual(metrics.channelCount, 1)
        XCTAssertEqual(metrics.level, .audible)
        await session.cancel()
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testCallbackFailureBeforeObservationRetainsSafeRenderErrorAndCleansUp() async {
        let capture = DiagnosticTapCaptureStub()
        let runtime = LiveAudioDiagnosticProcessTapRuntime(captureFactory: { _ in capture })
        let session = SystemAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(), runtime: runtime
        )
        do {
            _ = try await session.testSignal(duration: 3) {
                capture.emit(.failure(SystemAudioCaptureError.inputFailure(.renderFailed(-50))))
            }
            XCTFail("Expected the real capture failure")
        } catch {
            XCTAssertEqual(error as? SystemAudioCaptureError, .inputFailure(.renderFailed(-50)))
        }
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testObservationCancellationStopsPureAudioAndItsClockWithoutTimeout() async {
        let capture = DiagnosticTapCaptureStub()
        let clock = DiagnosticObservationClock()
        let runtime = LiveAudioDiagnosticProcessTapRuntime(
            captureFactory: { _ in capture }, observationSleeper: clock
        )
        let session = SystemAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(), runtime: runtime
        )
        let completed = expectation(description: "cancelled diagnostic returned")
        let caller = Task { () -> Bool in
            defer { completed.fulfill() }
            do { _ = try await session.testSignal(duration: 3) {}; return false }
            catch { return error is CancellationError }
        }
        await clock.waitUntilStarted()
        caller.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        let cancelled = await caller.value
        XCTAssertTrue(cancelled)
        await session.cancel()
        XCTAssertEqual(capture.stopCount, 1)
        let clockFinished = await clock.didFinish
        XCTAssertTrue(clockFinished)
    }

    func testLateCancelledStartupCannotStopOrPolluteReplacementDiagnostic() async throws {
        let barrier = DiagnosticTapBarrier()
        let entered = expectation(description: "old capture start blocked")
        let old = DiagnosticTapCaptureStub(startBarrier: barrier, entered: entered)
        let current = DiagnosticTapCaptureStub()
        let captures = DiagnosticTapSequence([old, current])
        let runtime = LiveAudioDiagnosticProcessTapRuntime(captureFactory: { _ in captures.next() })
        let first = Task { try await runtime.start(configuration: AudioDiagnosticSystemCaptureConfiguration()) }
        await fulfillment(of: [entered], timeout: 1)
        await runtime.stop()
        try await runtime.start(configuration: AudioDiagnosticSystemCaptureConfiguration())
        old.emit(.failure(SystemAudioCaptureError.inputFailed))
        old.emit(.frame(Self.toneFrame))
        current.emit(.frame(Self.toneFrame))
        await barrier.release()
        do { try await first.value; XCTFail("Expected stale startup cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(old.stopCount, 1)
        XCTAssertEqual(current.stopCount, 0)
        let metrics = try await runtime.measureSignal(duration: 0.05)
        XCTAssertEqual(metrics.sampleCount, Self.toneFrame.samples.count)
        await runtime.stop()
        XCTAssertEqual(current.stopCount, 1)
    }

    func testEntireOneSecondToneIsMeasuredBeforePlaybackCompletionReturns() async throws {
        let capture = DiagnosticTapCaptureStub()
        let runtime = LiveAudioDiagnosticProcessTapRuntime(captureFactory: { _ in capture })
        let session = SystemAudioDiagnosticSession(
            configuration: AudioDiagnosticSystemCaptureConfiguration(), runtime: runtime
        )
        // The real output tester waits for dataPlayedBack, rather than just
        // scheduling the tone. 512-frame AUHAL callbacks exceed 64 buffers
        // during that second; this must not falsely fail a healthy diagnostic.
        let metrics = try await session.testSignal(duration: 0.05) {
            for _ in 0..<100 { capture.emit(.frame(Self.toneFrame)) }
        }
        XCTAssertEqual(metrics.sampleCount, 51_200)
        XCTAssertEqual(metrics.level, .audible)
        XCTAssertEqual(metrics.observationDuration, 51_200.0 / 48_000, accuracy: 0.000_001)
        XCTAssertEqual(capture.stopCount, 1)
    }

    private static var toneFrame: CapturedAudioFrame {
        CapturedAudioFrame(timestamp: 0, sampleRate: 48_000, samples: Array(repeating: 0.2, count: 512))
    }
}

private final class DiagnosticTapCaptureStub: SystemAudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SystemAudioCaptureEvent) -> Void)?
    private var starts = 0
    private var stops = 0
    private let startBarrier: DiagnosticTapBarrier?
    private let entered: XCTestExpectation?

    init(startBarrier: DiagnosticTapBarrier? = nil, entered: XCTestExpectation? = nil) {
        self.startBarrier = startBarrier
        self.entered = entered
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    func start(onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) async throws {
        lock.withLock { starts += 1; handler = onEvent }
        entered?.fulfill()
        await startBarrier?.wait()
    }
    func stop() async { lock.withLock { stops += 1 } }
    // Deliberately retains the old handler to prove that late callbacks cannot
    // enter a new session even if the capture backend is non-cooperative.
    func emit(_ event: SystemAudioCaptureEvent) { lock.withLock { handler }?(event) }
}

private final class DiagnosticTapSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [DiagnosticTapCaptureStub]
    init(_ captures: [DiagnosticTapCaptureStub]) { self.captures = captures }
    func next() -> DiagnosticTapCaptureStub { lock.withLock { captures.removeFirst() } }
}

private actor DiagnosticTapBarrier {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor DiagnosticObservationClock: AudioDiagnosticTimeoutSleeping {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didFinish = false

    func sleep(for duration: TimeInterval) async throws {
        let pair = AsyncStream<Void>.makeStream()
        started = true
        let waiting = waiters; waiters = []; waiting.forEach { $0.resume() }
        for await _ in pair.stream {}
        didFinish = true
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
