import Foundation

actor OnlineAudioCaptureSource: AudioCaptureSource {
    private let microphone: any AudioCaptureSource
    private let systemSessionFactory: @Sendable () -> any SystemAudioCaptureSession
    private let now: @Sendable () -> TimeInterval
    private var active: OnlineAudioCaptureRun?

    init(microphoneCaptureSource: any AudioCaptureSource,
         systemSessionFactory: @escaping @Sendable () -> any SystemAudioCaptureSession = {
             CoreAudioProcessTapSession()
         }, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        microphone = microphoneCaptureSource
        self.systemSessionFactory = systemSessionFactory
        self.now = now
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioPacket, Error> {
        try Task.checkCancellation()
        guard active == nil else { throw AudioCaptureError.alreadyRunning }
        let pair = AsyncThrowingStream<CapturedAudioPacket, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(ScreenAudioCaptureConfiguration.packetBufferCapacity)
        )
        let id = UUID()
        let events = ScreenAudioEventFIFO<ScreenAudioRelayEvent>(
            capacity: ScreenAudioCaptureConfiguration.eventQueueCapacity,
            overflowEvent: { .failure(ScreenAudioCaptureError.deliveryOverflow) }
        ) { [weak self] event in
            await self?.consume(event, id: id)
        }
        let run = OnlineAudioCaptureRun(
            id: id, system: systemSessionFactory(), events: events,
            continuation: pair.continuation, startedAt: now()
        )
        active = run
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(id: id) }
        }

        let startup = Task { try await startRun(id: id) }
        run.startupTask = startup
        do {
            try await withTaskCancellationHandler {
                try await startup.value
                try Task.checkCancellation()
            } onCancel: { [weak self] in
                startup.cancel()
                Task { await self?.stop(id: id) }
            }
            try ensureCurrent(run)
            run.startupTask = nil
        } catch {
            await beginFinishing(run, error: error).value
            // An internal cleanup cancels startup as well. Preserve its first
            // real failure unless the external caller actually cancelled.
            if Task.isCancelled { throw CancellationError() }
            throw run.failure ?? error
        }
        return pair.stream
    }

    private func startRun(id: UUID) async throws {
        guard let run = active, run.id == id else { throw CancellationError() }
        let events = run.events
        do {
            guard await events.suspendAndWait() else { throw SystemAudioCaptureError.inputFailed }
            try ensureCurrent(run)
            try await run.system.start { [events, now] event in
                switch event {
                case let .frame(frame):
                    events.enqueue(.frame(frame, source: .system, receivedAt: now()))
                case let .failure(error):
                    events.close(afterEnqueueing: .failure(error))
                }
            }
            do { try ensureCurrent(run) }
            catch {
                // A non-cooperative old system start may finish after
                // stop/restart. Clean only that attempt's private tap.
                await run.system.stop()
                throw error
            }
            run.microphoneStartAttempted = true
            let microphoneStream = try await microphone.start()
            try ensureCurrent(run)
            run.microphoneTask = Task { [events, now] in
                do {
                    for try await packet in microphoneStream {
                        try Task.checkCancellation()
                        let frame = packet.master
                        // The per-run synchronizer anchors the first
                        // accepted frame, also after a pause. Do not carry
                        // a pre-pause microphone wall-clock anchor forward.
                        events.enqueue(.frame(frame, source: .microphone, receivedAt: now()))
                    }
                    events.close(afterEnqueueing: .failure(ScreenAudioCaptureError.microphoneStreamStopped))
                } catch {
                    events.close(afterEnqueueing: .failure(error))
                }
            }
            guard events.resume() else { throw SystemAudioCaptureError.inputFailed }
            run.isStarting = false
        } catch {
            // Cleanup may join this startup before stopping a microphone that
            // was still opening. Never join that cleanup from its own startup.
            _ = beginFinishing(run, error: error)
            throw error
        }
    }

    func pause() async throws {
        guard let run = active, !run.isStarting, run.cleanupTask == nil else { throw AudioCaptureError.notRunning }
        do {
            guard await run.events.suspendAndWait() else { throw AudioCaptureError.notRunning }
            try ensureCurrent(run)
            try await microphone.pause()
            try ensureCurrent(run)
            let packets = await run.mixer.flush()
            try ensureCurrent(run)
            try publish(packets, run: run)
            run.isPaused = true
        } catch {
            await beginFinishing(run, error: error).value
            throw error
        }
    }

    func resume() async throws {
        guard let run = active, run.isPaused, run.cleanupTask == nil else { throw AudioCaptureError.notRunning }
        // The tap clock runs during pause while some microphone backends stop
        // their sample clock. Re-anchor both to the same meeting wall clock;
        // keep the output origin and existing meeting timeline intact.
        run.synchronizer = ScreenAudioFrameSynchronizer(sessionStartedAt: run.startedAt)
        guard run.events.resume() else { throw AudioCaptureError.notRunning }
        do {
            try await microphone.resume()
            try ensureCurrent(run)
            run.isPaused = false
        } catch {
            await beginFinishing(run, error: error).value
            throw error
        }
    }

    func stop() async {
        guard let run = active else { return }
        await beginFinishing(run).value
    }

    private func stop(id: UUID) async {
        guard let run = active, run.id == id else { return }
        await beginFinishing(run).value
    }

    private func ensureCurrent(_ run: OnlineAudioCaptureRun) throws {
        try Task.checkCancellation()
        guard active === run, run.cleanupTask == nil else { throw CancellationError() }
    }

    private func consume(_ event: ScreenAudioRelayEvent, id: UUID) async {
        guard let run = active, run.id == id else { return }
        switch event {
        case let .frame(frame, source, receivedAt):
            // Accepted events are drained during stop before the final mixer
            // flush. Rejecting them merely because stop began loses the tail.
            let frames = run.synchronizer.ingest(frame, source: source, receivedAt: receivedAt)
            do {
                for frame in frames {
                    let packets = try await run.mixer.ingest(frame, source: source)
                    guard active === run else { return }
                    try publish(packets, run: run)
                }
            } catch { _ = beginFinishing(run, error: error) }
        case let .failure(error):
            // Never join the FIFO worker from inside its own event handler.
            _ = beginFinishing(run, error: error)
        }
    }

    private func publish(_ packets: [CapturedAudioPacket], run: OnlineAudioCaptureRun) throws {
        for packet in packets {
            let normalized = run.normalizer.normalize(try run.transcriptionBuilder.build(from: packet))
            _ = try ScreenAudioPacketDelivery.deliver(normalized, to: run.continuation)
        }
    }

    private func beginFinishing(_ run: OnlineAudioCaptureRun, error: Error? = nil) -> Task<Void, Never> {
        if let cleanup = run.cleanupTask { return cleanup }
        run.failure = error
        run.events.finishAccepting()
        run.startupTask?.cancel()
        run.microphoneTask?.cancel()
        let cleanup = Task { [self, run] in
            if run.microphoneStartAttempted {
                // MicrophoneCaptureSource cannot stop a provider until its
                // own start has returned. Cancel/settle that call first.
                _ = try? await run.startupTask?.value
                await microphone.stop()
            }
            run.startupTask = nil
            await run.microphoneTask?.value
            await run.system.stop()
            await run.events.finishAndWait()
            var terminalError = error
            do { try publish(await run.mixer.flush(), run: run) }
            catch { terminalError = error }
            run.transcriptionBuilder.reset()
            run.microphoneTask = nil
            run.continuation.finish(throwing: terminalError)
            if active === run { active = nil }
        }
        run.cleanupTask = cleanup
        return cleanup
    }
}

// Mutable state is accessed only by OnlineAudioCaptureSource's actor. Every
// run has its own queue, converters and mixer so late events cannot reset a
// restarted meeting's clock or emit into its continuation.
private final class OnlineAudioCaptureRun {
    let id: UUID
    let system: any SystemAudioCaptureSession
    let events: ScreenAudioEventFIFO<ScreenAudioRelayEvent>
    let continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    let startedAt: TimeInterval
    let mixer = RealtimeAudioMixer()
    let transcriptionBuilder = ScreenAudioTranscriptionFrameBuilder()
    var synchronizer: ScreenAudioFrameSynchronizer
    var normalizer = ScreenAudioPacketTimestampNormalizer()
    var microphoneTask: Task<Void, Never>?
    var startupTask: Task<Void, Error>?
    var cleanupTask: Task<Void, Never>?
    var failure: Error?
    var microphoneStartAttempted = false
    var isStarting = true
    var isPaused = false

    init(id: UUID, system: any SystemAudioCaptureSession,
         events: ScreenAudioEventFIFO<ScreenAudioRelayEvent>,
         continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation,
         startedAt: TimeInterval) {
        self.id = id; self.system = system; self.events = events; self.continuation = continuation
        self.startedAt = startedAt
        synchronizer = ScreenAudioFrameSynchronizer(sessionStartedAt: startedAt)
    }
}
