import ScreenCaptureKit
import XCTest
@testable import MeetingNotes

final class ScreenAudioCaptureConfigurationTests: XCTestCase {
    func testCapturesOnlySystemAndMicrophoneAudio() {
        let configuration = ScreenAudioCaptureConfiguration.makeStreamConfiguration()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 1)
        XCTAssertEqual(
            ScreenAudioCaptureConfiguration.eventQueueCapacity,
            256
        )
        XCTAssertEqual(
            ScreenAudioCaptureConfiguration.packetBufferCapacity,
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

    func testPacketDeliveryFailsExplicitlyAndTerminatesAfterBufferOverflow() async {
        let pair = AsyncThrowingStream<
            CapturedAudioPacket,
            Error
        >.makeStream(bufferingPolicy: .bufferingOldest(1))
        let first = packet(timestamp: 0)
        let dropped = packet(timestamp: 0.02)
        let rejectedAfterTermination = packet(timestamp: 0.04)

        XCTAssertEqual(
            try ScreenAudioPacketDelivery.deliver(
                first,
                to: pair.continuation
            ),
            .enqueued
        )
        XCTAssertThrowsError(
            try ScreenAudioPacketDelivery.deliver(
                dropped,
                to: pair.continuation
            )
        ) { error in
            XCTAssertEqual(
                error as? ScreenAudioCaptureError,
                .packetBufferOverflow
            )
        }
        XCTAssertEqual(
            try ScreenAudioPacketDelivery.deliver(
                rejectedAfterTermination,
                to: pair.continuation
            ),
            .terminated
        )

        var received: [CapturedAudioPacket] = []
        var terminalError: Error?
        do {
            for try await packet in pair.stream {
                received.append(packet)
            }
        } catch {
            terminalError = error
        }

        XCTAssertEqual(received, [first])
        XCTAssertEqual(
            terminalError as? ScreenAudioCaptureError,
            .packetBufferOverflow
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

    func testBuilds16kTranscriptionPayloadWithoutChanging48kStorage() throws {
        let builder = ScreenAudioTranscriptionFrameBuilder()
        let master = CapturedAudioFrame(
            timestamp: 0.5,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: Array(repeating: 0.2, count: 4_800)
        )
        let microphone = CapturedAudioFrame(
            timestamp: 0.5,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: Array(repeating: 0.1, count: 4_800)
        )
        let system = CapturedAudioFrame(
            timestamp: 0.5,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: Array(repeating: 0.3, count: 4_800)
        )
        let storage = CapturedAudioPacket(
            master: master,
            sourceFrames: [
                .microphone: microphone,
                .system: system,
            ]
        )

        let output = try builder.build(from: storage)

        XCTAssertEqual(output.master.timestamp, 0.5)
        XCTAssertEqual(output.master.sampleRate, 48_000)
        XCTAssertEqual(output.master.samples, master.samples)
        XCTAssertEqual(output.master.transcriptionSampleRate, 16_000)
        let transcriptionSamples = try XCTUnwrap(
            output.master.transcriptionSamples
        )
        XCTAssertEqual(transcriptionSamples.count, 1_600)
        XCTAssertEqual(
            transcriptionSamples[transcriptionSamples.count / 2],
            0.2,
            accuracy: 0.001
        )
        XCTAssertEqual(output.sourceFrames[.microphone], microphone)
        XCTAssertEqual(output.sourceFrames[.system], system)
        XCTAssertNil(output.sourceFrames[.microphone]?.transcriptionSamples)
        XCTAssertNil(output.sourceFrames[.system]?.transcriptionSamples)
    }

    func testPacketTimestampNormalizerUsesOneOriginForMasterAndSources() throws {
        var normalizer = ScreenAudioPacketTimestampNormalizer()
        let first = packet(timestamp: 3.5)
        let second = packet(timestamp: 3.52)

        let normalizedFirst = normalizer.normalize(first)
        let normalizedSecond = normalizer.normalize(second)

        XCTAssertEqual(normalizedFirst.master.timestamp, 0)
        XCTAssertEqual(
            normalizedFirst.sourceFrames[.microphone]?.timestamp,
            0
        )
        XCTAssertEqual(normalizedFirst.sourceFrames[.system]?.timestamp, 0)
        XCTAssertEqual(
            normalizedSecond.master.timestamp,
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                normalizedSecond.sourceFrames[.microphone]?.timestamp
            ),
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(normalizedSecond.sourceFrames[.system]?.timestamp),
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            normalizedSecond.sourceFrames[.microphone]?.sampleRate,
            48_000
        )
        XCTAssertEqual(
            normalizedSecond.sourceFrames[.system]?.sampleRate,
            48_000
        )
    }

    func testTranscriptionFrameBuilderConvertsAfterSessionReset() throws {
        let builder = ScreenAudioTranscriptionFrameBuilder()
        let firstSessionSamples = (0..<4_097).map { index in
            Float((index % 97) - 48) / 240
        }
        _ = try builder.build(
            from: CapturedAudioFrame(
                timestamp: 0,
                sampleRate: PCMConverter.playbackSampleRate,
                samples: firstSessionSamples
            )
        )

        builder.reset()
        let secondSessionSamples = (0..<4_097).map { index in
            Float(((index * 17) % 211) - 105) / 525
        }
        let secondSessionFrame = CapturedAudioFrame(
            timestamp: 1,
            sampleRate: PCMConverter.playbackSampleRate,
            samples: secondSessionSamples
        )
        let outputAfterReset = try builder.build(from: secondSessionFrame)
        let freshOutput = try ScreenAudioTranscriptionFrameBuilder().build(
            from: secondSessionFrame
        )

        XCTAssertEqual(outputAfterReset.timestamp, freshOutput.timestamp)
        XCTAssertEqual(outputAfterReset.sampleRate, freshOutput.sampleRate)
        XCTAssertEqual(outputAfterReset.samples, freshOutput.samples)
        XCTAssertEqual(
            outputAfterReset.transcriptionSampleRate,
            freshOutput.transcriptionSampleRate
        )
        let outputSamples = try XCTUnwrap(
            outputAfterReset.transcriptionSamples
        )
        let freshSamples = try XCTUnwrap(freshOutput.transcriptionSamples)
        XCTAssertEqual(outputSamples.count, freshSamples.count)
        for (outputSample, freshSample) in zip(outputSamples, freshSamples) {
            XCTAssertEqual(outputSample, freshSample, accuracy: 0.000_001)
        }
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

    private func packet(timestamp: TimeInterval) -> CapturedAudioPacket {
        let master = CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: 48_000,
            samples: [0.5]
        )
        return CapturedAudioPacket(
            master: master,
            sourceFrames: [
                .microphone: CapturedAudioFrame(
                    timestamp: timestamp,
                    sampleRate: 48_000,
                    samples: [0.2]
                ),
                .system: CapturedAudioFrame(
                    timestamp: timestamp,
                    sampleRate: 48_000,
                    samples: [0.3]
                ),
            ]
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
