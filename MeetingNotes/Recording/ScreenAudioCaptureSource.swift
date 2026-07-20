import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenAudioCaptureError: Error, Equatable, Sendable {
    case screenRecordingDenied
    case noDisplayAvailable
    case streamSetupFailed
    case streamStartFailed
    case streamStopped
    case invalidAudioSample
    case deliveryOverflow
}

enum ScreenAudioCaptureConfiguration {
    static let eventQueueCapacity = 256

    static let registeredOutputTypes: [SCStreamOutputType] = [
        .audio,
        .microphone
    ]

    static func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(PCMConverter.playbackSampleRate)
        configuration.channelCount = 1
        return configuration
    }
}

struct ScreenAudioFrameSynchronizer {
    private struct PendingFrame {
        let frame: CapturedAudioFrame
        let receivedAt: TimeInterval
    }

    private struct SourceTiming {
        let inputOrigin: TimeInterval
        let sessionOffset: TimeInterval
        var nextTimestamp: TimeInterval
    }

    private let sessionStartedAt: TimeInterval
    private var timingBySource: [RealtimeAudioSource: SourceTiming] = [:]

    init(sessionStartedAt: TimeInterval) {
        self.sessionStartedAt = sessionStartedAt
    }

    mutating func ingest(
        _ frame: CapturedAudioFrame,
        source: RealtimeAudioSource,
        receivedAt: TimeInterval
    ) -> [CapturedAudioFrame] {
        let pending = PendingFrame(
            frame: frame,
            receivedAt: receivedAt
        )
        return [normalize(pending, source: source)]
    }

    private mutating func normalize(
        _ pending: PendingFrame,
        source: RealtimeAudioSource
    ) -> CapturedAudioFrame {
        let frame = pending.frame
        let timestamp: TimeInterval
        if var timing = timingBySource[source] {
            let sourceRelativeTimestamp = max(
                0,
                frame.timestamp - timing.inputOrigin
            )
            timestamp = max(
                timing.nextTimestamp,
                timing.sessionOffset + sourceRelativeTimestamp
            )
            timing.nextTimestamp = timestamp + frameDuration(frame)
            timingBySource[source] = timing
        } else {
            let sessionOffset = max(
                0,
                pending.receivedAt - sessionStartedAt
            )
            timestamp = sessionOffset
            timingBySource[source] = SourceTiming(
                inputOrigin: frame.timestamp,
                sessionOffset: sessionOffset,
                nextTimestamp: sessionOffset + frameDuration(frame)
            )
        }
        return CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            samples: frame.samples,
            transcriptionSamples: frame.transcriptionSamples,
            transcriptionSampleRate: frame.transcriptionSampleRate
        )
    }

    private func frameDuration(_ frame: CapturedAudioFrame) -> TimeInterval {
        guard frame.sampleRate > 0 else { return 0 }
        return Double(frame.samples.count) / frame.sampleRate
    }
}

enum ScreenAudioDecodeDelivery {
    static func deliver<Frame>(
        decode: () throws -> Frame,
        onFrame: (Frame) -> Void,
        onFailure: (Error) -> Void
    ) {
        do {
            onFrame(try decode())
        } catch {
            onFailure(error)
        }
    }
}

enum ScreenAudioCallbackBarrier {
    static func wait(for queues: [DispatchQueue]) async {
        guard !queues.isEmpty else { return }
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            for queue in queues {
                group.enter()
                queue.async {
                    group.leave()
                }
            }
            group.notify(
                queue: DispatchQueue.global(qos: .userInitiated)
            ) {
                continuation.resume()
            }
        }
    }
}

final class ScreenAudioCallbackGate: @unchecked Sendable {
    private enum State {
        case accepting
        case suspended
        case finished
    }

    private let lock = NSLock()
    private var state = State.accepting

    func beginDelivery() -> Bool {
        lock.withLock {
            state == .accepting
        }
    }

    @discardableResult
    func suspend() -> Bool {
        lock.withLock {
            guard state != .finished else { return false }
            state = .suspended
            return true
        }
    }

    @discardableResult
    func resume() -> Bool {
        lock.withLock {
            guard state != .finished else { return false }
            state = .accepting
            return true
        }
    }

    func finish() {
        lock.withLock {
            state = .finished
        }
    }
}

final class ScreenAudioEventFIFO<Event: Sendable>: @unchecked Sendable {
    private enum State {
        case accepting
        case suspended
        case finished
    }

    private enum Item: Sendable {
        case event(Event)
        case barrier(CheckedContinuation<Void, Never>)
        case suspensionBarrier(CheckedContinuation<Bool, Never>)
    }

    private let lock = NSLock()
    private let continuation: AsyncStream<Item>.Continuation
    private let capacity: Int
    private let overflowEvent: Event
    private var workerTask: Task<Void, Never>?
    private var state = State.accepting
    private var pendingEventCount = 0

    init(
        capacity: Int,
        overflowEvent: @escaping @Sendable () -> Event,
        handler: @escaping @Sendable (Event) async -> Void
    ) {
        let pair = AsyncStream<Item>.makeStream()
        continuation = pair.continuation
        self.capacity = max(1, capacity)
        self.overflowEvent = overflowEvent()
        workerTask = Task { [weak self] in
            for await item in pair.stream {
                switch item {
                case let .event(event):
                    await handler(event)
                    self?.didProcessEvent()
                case let .barrier(barrier):
                    barrier.resume()
                case let .suspensionBarrier(barrier):
                    barrier.resume(
                        returning: self?.isSuspended() ?? false
                    )
                }
            }
        }
    }

    @discardableResult
    func enqueue(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .accepting else { return false }
        guard pendingEventCount < capacity else {
            state = .finished
            pendingEventCount += 1
            continuation.yield(.event(overflowEvent))
            continuation.finish()
            return false
        }
        pendingEventCount += 1
        continuation.yield(.event(event))
        return true
    }

    func suspendAndWait() async -> Bool {
        let didSuspend = await withCheckedContinuation { (
            barrier: CheckedContinuation<Bool, Never>
        ) in
            lock.lock()
            guard state != .finished else {
                lock.unlock()
                barrier.resume(returning: false)
                return
            }
            state = .suspended
            continuation.yield(.suspensionBarrier(barrier))
            lock.unlock()
        }
        if !didSuspend {
            await workerTask?.value
        }
        return didSuspend
    }

    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .finished else { return false }
        if state == .suspended {
            state = .accepting
        }
        return true
    }

    @discardableResult
    func close(afterEnqueueing event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .finished else { return false }
        state = .finished
        pendingEventCount += 1
        continuation.yield(.event(event))
        continuation.finish()
        return true
    }

    @discardableResult
    func finishAccepting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .finished else { return false }
        state = .finished
        continuation.finish()
        return true
    }

    func finishAndWait() async {
        await withCheckedContinuation { barrier in
            lock.lock()
            guard state != .finished else {
                lock.unlock()
                barrier.resume()
                return
            }
            state = .finished
            continuation.yield(.barrier(barrier))
            continuation.finish()
            lock.unlock()
        }
        await workerTask?.value
    }

    private func didProcessEvent() {
        lock.lock()
        pendingEventCount = max(0, pendingEventCount - 1)
        lock.unlock()
    }

    private func isSuspended() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .suspended
    }
}

private enum ScreenAudioRelayEvent: @unchecked Sendable {
    case frame(
        CapturedAudioFrame,
        source: RealtimeAudioSource,
        receivedAt: TimeInterval
    )
    case failure(Error)
}

final class ScreenAudioTranscriptionFrameBuilder: @unchecked Sendable {
    private let converter: PCMConverter

    init(
        converter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.defaultOutputSampleRate,
            amplitudePolicy: .preserveAmplitude
        )
    ) {
        self.converter = converter
    }

    func build(
        from storageFrame: CapturedAudioFrame
    ) throws -> CapturedAudioFrame {
        let transcriptionFrame = try converter.convert(storageFrame)
        return CapturedAudioFrame(
            timestamp: storageFrame.timestamp,
            sampleRate: storageFrame.sampleRate,
            channelCount: storageFrame.channelCount,
            samples: storageFrame.samples,
            transcriptionSamples: transcriptionFrame.samples,
            transcriptionSampleRate: transcriptionFrame.sampleRate
        )
    }

    func reset() {
        converter.reset()
    }
}

actor ScreenAudioCaptureSource: AudioCaptureSource {
    private let mixer: RealtimeAudioMixer
    private let decoder: ScreenAudioSampleDecoder
    private let transcriptionFrameBuilder: ScreenAudioTranscriptionFrameBuilder
    private let systemQueue = DispatchQueue(
        label: "MeetingNotes.ScreenAudio.System",
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: "MeetingNotes.ScreenAudio.Microphone",
        qos: .userInitiated
    )
    private var stream: SCStream?
    private var relay: ScreenAudioStreamRelay?
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var outputTimestampOrigin: TimeInterval?
    private var frameSynchronizer: ScreenAudioFrameSynchronizer?

    init(
        mixer: RealtimeAudioMixer = RealtimeAudioMixer(),
        decoder: ScreenAudioSampleDecoder = ScreenAudioSampleDecoder(),
        transcriptionFrameBuilder: ScreenAudioTranscriptionFrameBuilder =
            ScreenAudioTranscriptionFrameBuilder()
    ) {
        self.mixer = mixer
        self.decoder = decoder
        self.transcriptionFrameBuilder = transcriptionFrameBuilder
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        guard stream == nil else {
            throw AudioCaptureError.alreadyRunning
        }
        resetConverters()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if ScreenCaptureProbeResult(error: error) == .denied {
                throw ScreenAudioCaptureError.screenRecordingDenied
            }
            throw ScreenAudioCaptureError.streamSetupFailed
        }
        guard let display = content.displays.first else {
            throw ScreenAudioCaptureError.noDisplayAvailable
        }
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = ScreenAudioCaptureConfiguration.makeStreamConfiguration()
        let streamPair = AsyncThrowingStream<CapturedAudioFrame, Error>.makeStream()
        continuation = streamPair.continuation
        outputTimestampOrigin = nil
        frameSynchronizer = ScreenAudioFrameSynchronizer(
            sessionStartedAt: ProcessInfo.processInfo.systemUptime
        )

        let source = self
        let relay = ScreenAudioStreamRelay(
            decoder: decoder,
            eventHandler: { [weak source] event in
                guard let source else { return }
                switch event {
                case let .frame(frame, audioSource, receivedAt):
                    await source.consume(
                        frame,
                        source: audioSource,
                        receivedAt: receivedAt
                    )
                case let .failure(error):
                    await source.handleStreamFailure(error)
                }
            }
        )
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: relay
        )

        do {
            for outputType in ScreenAudioCaptureConfiguration.registeredOutputTypes {
                try stream.addStreamOutput(
                    relay,
                    type: outputType,
                    sampleHandlerQueue: queue(for: outputType)
                )
            }
        } catch {
            removeRegisteredOutputs(from: stream, relay: relay)
            await waitForCallbackQueues()
            await relay.finishAndWait()
            resetConverters()
            frameSynchronizer = nil
            continuation?.finish(throwing: ScreenAudioCaptureError.streamSetupFailed)
            continuation = nil
            throw ScreenAudioCaptureError.streamSetupFailed
        }

        self.stream = stream
        self.relay = relay
        do {
            try await stream.startCapture()
        } catch {
            removeRegisteredOutputs(from: stream, relay: relay)
            await waitForCallbackQueues()
            await relay.finishAndWait()
            resetConverters()
            frameSynchronizer = nil
            self.stream = nil
            self.relay = nil
            continuation?.finish(throwing: ScreenAudioCaptureError.streamStartFailed)
            continuation = nil
            throw ScreenAudioCaptureError.streamStartFailed
        }
        return streamPair.stream
    }

    func pause() async throws {
        guard stream != nil, continuation != nil, let relay else {
            throw AudioCaptureError.notRunning
        }
        guard await relay.suspendAndWait(
            callbackQueues: [systemQueue, microphoneQueue]
        ),
              stream != nil,
              continuation != nil else {
            throw AudioCaptureError.notRunning
        }
        do {
            try yieldMixedFrames(await mixer.flush())
        } catch {
            await handleStreamFailure(error)
            throw error
        }
    }

    func resume() async throws {
        guard stream != nil, continuation != nil, let relay else {
            throw AudioCaptureError.notRunning
        }
        guard relay.resume() else {
            throw AudioCaptureError.notRunning
        }
    }

    func stop() async {
        guard let stream, let relay else {
            resetConverters()
            return
        }
        try? await stream.stopCapture()
        removeRegisteredOutputs(from: stream, relay: relay)
        await waitForCallbackQueues()
        await relay.finishAndWait()
        do {
            try yieldMixedFrames(await mixer.flush())
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
        resetConverters()
        continuation = nil
        self.stream = nil
        self.relay = nil
        outputTimestampOrigin = nil
        frameSynchronizer = nil
    }

    private func queue(for outputType: SCStreamOutputType) -> DispatchQueue {
        outputType == .microphone ? microphoneQueue : systemQueue
    }

    private func removeRegisteredOutputs(
        from stream: SCStream,
        relay: ScreenAudioStreamRelay
    ) {
        for outputType in ScreenAudioCaptureConfiguration.registeredOutputTypes {
            try? stream.removeStreamOutput(relay, type: outputType)
        }
    }

    private func waitForCallbackQueues() async {
        await ScreenAudioCallbackBarrier.wait(
            for: [systemQueue, microphoneQueue]
        )
    }

    private func consume(
        _ frame: CapturedAudioFrame,
        source: RealtimeAudioSource,
        receivedAt: TimeInterval
    ) async {
        guard stream != nil, var frameSynchronizer else {
            return
        }
        let orderedFrames = frameSynchronizer.ingest(
            frame,
            source: source,
            receivedAt: receivedAt
        )
        self.frameSynchronizer = frameSynchronizer
        do {
            for orderedFrame in orderedFrames {
                let mixedFrames = try await mixer.ingest(
                    orderedFrame,
                    source: source
                )
                try yieldMixedFrames(mixedFrames)
            }
        } catch {
            await handleStreamFailure(error)
        }
    }

    private func normalizeOutputTimestamp(
        _ frame: CapturedAudioFrame
    ) -> CapturedAudioFrame {
        if outputTimestampOrigin == nil {
            outputTimestampOrigin = frame.timestamp
        }
        let origin = outputTimestampOrigin ?? frame.timestamp
        return CapturedAudioFrame(
            timestamp: max(0, frame.timestamp - origin),
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            samples: frame.samples,
            transcriptionSamples: frame.transcriptionSamples,
            transcriptionSampleRate: frame.transcriptionSampleRate
        )
    }

    private func yieldMixedFrames(
        _ frames: [CapturedAudioFrame]
    ) throws {
        for frame in frames {
            let output = try transcriptionFrameBuilder.build(from: frame)
            continuation?.yield(normalizeOutputTimestamp(output))
        }
    }

    private func resetConverters() {
        decoder.reset()
        transcriptionFrameBuilder.reset()
    }

    private func handleStreamFailure(_ error: Error) async {
        guard stream != nil, continuation != nil else {
            return
        }
        if let stream, let relay {
            relay.finishAccepting()
            try? await stream.stopCapture()
            removeRegisteredOutputs(from: stream, relay: relay)
            await waitForCallbackQueues()
        }
        var completionError = error
        do {
            try yieldMixedFrames(await mixer.flush())
        } catch {
            completionError = error
        }
        resetConverters()
        continuation?.finish(throwing: completionError)
        continuation = nil
        stream = nil
        relay = nil
        outputTimestampOrigin = nil
        frameSynchronizer = nil
    }
}

final class ScreenAudioSampleDecoder: @unchecked Sendable {
    private let systemConverter: PCMConverter
    private let microphoneConverter: PCMConverter

    init(
        systemConverter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.playbackSampleRate,
            amplitudePolicy: .preserveAmplitude
        ),
        microphoneConverter: PCMConverter = PCMConverter(
            outputSampleRate: PCMConverter.playbackSampleRate,
            amplitudePolicy: .preserveAmplitude
        )
    ) {
        self.systemConverter = systemConverter
        self.microphoneConverter = microphoneConverter
    }

    func reset() {
        systemConverter.reset()
        microphoneConverter.reset()
    }

    func decode(
        _ sampleBuffer: CMSampleBuffer,
        source: RealtimeAudioSource
    ) throws -> CapturedAudioFrame {
        guard sampleBuffer.isValid else {
            throw ScreenAudioCaptureError.invalidAudioSample
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(presentationTime)
        guard timestamp.isFinite else {
            throw ScreenAudioCaptureError.invalidAudioSample
        }
        let converter = switch source {
        case .system: systemConverter
        case .microphone: microphoneConverter
        }

        return try sampleBuffer.withAudioBufferList {
            audioBufferList,
            _ -> CapturedAudioFrame in
            guard let description = sampleBuffer.formatDescription?
                .audioStreamBasicDescription,
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame
                ),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else {
                throw ScreenAudioCaptureError.invalidAudioSample
            }
            return try converter.convert(buffer, timestamp: timestamp)
        }
    }
}

private final class ScreenAudioStreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let decoder: ScreenAudioSampleDecoder
    private let events: ScreenAudioEventFIFO<ScreenAudioRelayEvent>
    private let callbackGate = ScreenAudioCallbackGate()

    init(
        decoder: ScreenAudioSampleDecoder,
        eventHandler: @escaping @Sendable (
            ScreenAudioRelayEvent
        ) async -> Void
    ) {
        self.decoder = decoder
        events = ScreenAudioEventFIFO(
            capacity: ScreenAudioCaptureConfiguration.eventQueueCapacity,
            overflowEvent: {
                .failure(ScreenAudioCaptureError.deliveryOverflow)
            },
            handler: eventHandler
        )
    }

    func suspendAndWait(callbackQueues: [DispatchQueue]) async -> Bool {
        guard callbackGate.suspend() else { return false }
        await ScreenAudioCallbackBarrier.wait(for: callbackQueues)
        return await events.suspendAndWait()
    }

    func resume() -> Bool {
        guard events.resume() else { return false }
        return callbackGate.resume()
    }

    func finishAndWait() async {
        await events.finishAndWait()
    }

    func finishAccepting() {
        callbackGate.finish()
        events.finishAccepting()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        _ = stream
        guard callbackGate.beginDelivery() else { return }
        let source: RealtimeAudioSource
        switch outputType {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }
        let receivedAt = ProcessInfo.processInfo.systemUptime
        ScreenAudioDecodeDelivery.deliver(
            decode: {
                try decoder.decode(sampleBuffer, source: source)
            },
            onFrame: { frame in
                events.enqueue(
                    .frame(
                        frame,
                        source: source,
                        receivedAt: receivedAt
                    )
                )
            },
            onFailure: { error in
                events.close(afterEnqueueing: .failure(error))
            }
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        _ = stream
        events.close(afterEnqueueing: .failure(error))
    }
}
