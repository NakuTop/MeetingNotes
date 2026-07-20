import ScreenCaptureKit
import XCTest
@testable import MeetingNotes

final class ScreenAudioCaptureConfigurationTests: XCTestCase {
    func testCapturesOnlySystemAndMicrophoneAudio() {
        let configuration = ScreenAudioCaptureConfiguration.makeStreamConfiguration()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 16_000)
        XCTAssertEqual(configuration.channelCount, 1)
        XCTAssertEqual(
            ScreenAudioCaptureConfiguration.eventQueueCapacity,
            256
        )
        XCTAssertEqual(
            ScreenAudioCaptureConfiguration.registeredOutputTypes,
            [.audio, .microphone]
        )
        XCTAssertFalse(
            ScreenAudioCaptureConfiguration.registeredOutputTypes.contains(.screen)
        )
    }

    func testSynchronizerAlignsIndependentPTSOriginsToSessionArrival() {
        var synchronizer = ScreenAudioFrameSynchronizer(
            sessionStartedAt: 100
        )

        let systemFrames = synchronizer.ingest(
            frame(timestamp: 5_000, sample: 0.5),
            source: .system,
            receivedAt: 100.01
        )
        let microphoneFrames = synchronizer.ingest(
            frame(timestamp: 20, sample: 0.25),
            source: .microphone,
            receivedAt: 100.03
        )

        XCTAssertEqual(systemFrames.count, 1)
        XCTAssertEqual(microphoneFrames.count, 1)
        XCTAssertEqual(systemFrames[0].timestamp, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(microphoneFrames[0].timestamp, 0.03, accuracy: 0.000_001)
    }

    func testFIFOProcessesAcceptedEventsBeforeSuspending() async {
        let recorder = ScreenAudioEventRecorder<Int>()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
        }

        XCTAssertTrue(queue.enqueue(1))
        XCTAssertTrue(queue.enqueue(2))
        let didSuspend = await queue.suspendAndWait()

        let suspendedValues = await recorder.values()
        XCTAssertTrue(didSuspend)
        XCTAssertEqual(suspendedValues, [1, 2])
        XCTAssertFalse(queue.enqueue(3))

        XCTAssertTrue(queue.resume())
        XCTAssertTrue(queue.enqueue(3))
        await queue.finishAndWait()
        let finishedValues = await recorder.values()
        XCTAssertEqual(finishedValues, [1, 2, 3])
    }

    func testFIFOFinishDrainsAcceptedEventsAndRejectsNewEvents() async {
        let recorder = ScreenAudioEventRecorder<Int>()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
        }

        XCTAssertTrue(queue.enqueue(1))
        XCTAssertTrue(queue.enqueue(2))
        await queue.finishAndWait()

        let finishedValues = await recorder.values()
        XCTAssertEqual(finishedValues, [1, 2])
        XCTAssertFalse(queue.enqueue(3))
    }

    func testFIFOFailureClosesEntranceAfterQueuedEvents() async {
        let recorder = ScreenAudioEventRecorder<Int>()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
        }

        XCTAssertTrue(queue.enqueue(1))
        XCTAssertTrue(queue.close(afterEnqueueing: 99))
        XCTAssertFalse(queue.enqueue(2))
        await queue.finishAndWait()

        let finishedValues = await recorder.values()
        XCTAssertEqual(finishedValues, [1, 99])
    }

    func testFIFORepeatedFailureAndFinishAreIdempotent() async {
        let recorder = ScreenAudioEventRecorder<Int>()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
        }

        XCTAssertTrue(queue.enqueue(1))
        XCTAssertTrue(queue.close(afterEnqueueing: 99))
        XCTAssertFalse(queue.close(afterEnqueueing: 100))
        await queue.finishAndWait()
        await queue.finishAndWait()

        let finishedValues = await recorder.values()
        XCTAssertEqual(finishedValues, [1, 99])
        XCTAssertFalse(queue.enqueue(2))
    }

    func testFIFOHandlerCanFinishEntranceWithoutWaitingOnItself() async {
        let recorder = ScreenAudioEventRecorder<Int>()
        let finished = ScreenAudioTestSignal()
        let queueReference = ScreenAudioFIFOReference<Int>()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
            queueReference.finishAccepting()
            await finished.signal()
        }
        queueReference.set(queue)

        XCTAssertTrue(queue.enqueue(1))
        await finished.wait()
        XCTAssertFalse(queue.enqueue(2))
        await queue.finishAndWait()

        let values = await recorder.values()
        XCTAssertEqual(values, [1])
    }

    func testFIFOOverflowQueuesExactlyOneFailureAndRejectsMoreEvents() async {
        let gate = ScreenAudioTestGate()
        let recorder = ScreenAudioEventRecorder<Int>()
        let started = ScreenAudioTestSignal()
        let queue = ScreenAudioEventFIFO<Int>(
            capacity: 2,
            overflowEvent: { 99 }
        ) { event in
            if event == 1 {
                await started.signal()
                await gate.wait()
            }
            await recorder.append(event)
        }

        XCTAssertTrue(queue.enqueue(1))
        await started.wait()
        XCTAssertTrue(queue.enqueue(2))
        XCTAssertFalse(queue.enqueue(3))
        XCTAssertFalse(queue.enqueue(4))
        await gate.open()
        await queue.finishAndWait()

        let values = await recorder.values()
        XCTAssertEqual(values, [1, 2, 99])
    }

    func testPauseGateRejectsLateCallbacksAndDrainsAcceptedDecode() async {
        let systemQueue = DispatchQueue(
            label: "ScreenAudioTests.System",
            qos: .userInitiated
        )
        let microphoneQueue = DispatchQueue(
            label: "ScreenAudioTests.Microphone",
            qos: .userInitiated
        )
        let callbackGate = ScreenAudioCallbackGate()
        let recorder = ScreenAudioEventRecorder<Int>()
        let fifo = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            await recorder.append(event)
        }

        XCTAssertTrue(callbackGate.beginDelivery())
        XCTAssertTrue(callbackGate.suspend())
        XCTAssertFalse(callbackGate.beginDelivery())

        systemQueue.async {
            fifo.enqueue(1)
        }
        microphoneQueue.async {
            guard callbackGate.beginDelivery() else { return }
            fifo.enqueue(99)
        }
        await ScreenAudioCallbackBarrier.wait(
            for: [systemQueue, microphoneQueue]
        )
        let didSuspend = await fifo.suspendAndWait()

        XCTAssertTrue(didSuspend)
        let values = await recorder.values()
        XCTAssertEqual(values, [1])
        XCTAssertTrue(fifo.resume())
        XCTAssertTrue(callbackGate.resume())
        XCTAssertTrue(callbackGate.beginDelivery())
        await fifo.finishAndWait()
    }

    func testFinishedFIFOPauseWaitsForWorkerAndResumeRejects() async {
        let gate = ScreenAudioTestGate()
        let started = ScreenAudioTestSignal()
        let pauseFinished = ScreenAudioTestCompletion()
        let recorder = ScreenAudioEventRecorder<Int>()
        let fifo = ScreenAudioEventFIFO<Int>(
            capacity: 8,
            overflowEvent: { -1 }
        ) { event in
            if event == 1 {
                await started.signal()
                await gate.wait()
            }
            await recorder.append(event)
        }

        XCTAssertTrue(fifo.enqueue(1))
        await started.wait()
        XCTAssertTrue(fifo.close(afterEnqueueing: 99))
        let pausing = Task {
            let result = await fifo.suspendAndWait()
            await pauseFinished.markCompleted()
            return result
        }
        await Task.yield()
        let completedWhileFailureBlocked = await pauseFinished.isCompleted()
        XCTAssertFalse(completedWhileFailureBlocked)

        await gate.open()
        let didSuspend = await pausing.value

        XCTAssertFalse(didSuspend)
        XCTAssertFalse(fifo.resume())
        let values = await recorder.values()
        XCTAssertEqual(values, [1, 99])
    }

    func testDecodeFailureIsReportedInsteadOfSilentlyDropped() {
        var deliveredFrames = 0
        var receivedError: Error?

        ScreenAudioDecodeDelivery.deliver(
            decode: {
                throw ScreenAudioCaptureError.invalidAudioSample
            },
            onFrame: { _ in deliveredFrames += 1 },
            onFailure: { receivedError = $0 }
        )

        XCTAssertEqual(deliveredFrames, 0)
        XCTAssertEqual(
            receivedError as? ScreenAudioCaptureError,
            .invalidAudioSample
        )
    }

    private func frame(
        timestamp: TimeInterval,
        sample: Float
    ) -> CapturedAudioFrame {
        CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: 16_000,
            channelCount: 1,
            samples: [sample]
        )
    }
}

private actor ScreenAudioEventRecorder<Value: Sendable> {
    private var recordedValues: [Value] = []

    func append(_ value: Value) {
        recordedValues.append(value)
    }

    func values() -> [Value] {
        recordedValues
    }
}

private final class ScreenAudioFIFOReference<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var queue: ScreenAudioEventFIFO<Value>?

    func set(_ queue: ScreenAudioEventFIFO<Value>) {
        lock.withLock {
            self.queue = queue
        }
    }

    func finishAccepting() {
        let currentQueue: ScreenAudioEventFIFO<Value>? = lock.withLock {
            self.queue
        }
        currentQueue?.finishAccepting()
    }
}

private actor ScreenAudioTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ScreenAudioTestGate {
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

private actor ScreenAudioTestCompletion {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}
