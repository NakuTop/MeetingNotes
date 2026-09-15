import FluidAudio
import Foundation

struct LiveSpeakerBatch: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let source: TranscriptAudioSource
    // IDs are session-stable, not per-chunk cluster numbers.
    let intervals: [SpeakerInterval]
    var failureCode: String? = nil
}

protocol LiveSpeakerAnalyzing: Sendable {
    func analyze(samples: [Float], startingAt: TimeInterval) async throws -> [SpeakerInterval]
}

protocol LiveSpeakerSession: Sendable {
    func updates() async -> AsyncStream<LiveSpeakerBatch>
    func enqueue(samples: [Float], startingAt: TimeInterval) async
    func cancel() async
}

protocol LiveSpeakerSessionCreating: Sendable {
    func makeSession(mode: MeetingMode) -> any LiveSpeakerSession
}

struct FluidAudioLiveSpeakerSessionFactory: LiveSpeakerSessionCreating {
    let modelsDirectory: URL

    func makeSession(mode: MeetingMode) -> any LiveSpeakerSession {
        LiveSpeakerAttributionQueue(
            engine: FluidAudioLiveSpeakerEngine(modelsDirectory: modelsDirectory),
            mode: mode
        )
    }
}

// The capture path only enqueues bounded 16 kHz chunks. Model preparation and
// inference never block Whisper delivery or run on the main/real-time thread.
actor LiveSpeakerAttributionQueue: LiveSpeakerSession {
    private let engine: any LiveSpeakerAnalyzing
    private let mode: MeetingMode
    private let maximumPendingChunks: Int
    private var pending: [MeetingAudioSampleChunk] = []
    private var worker: Task<Void, Never>?
    private var continuation: AsyncStream<LiveSpeakerBatch>.Continuation?
    private var cancelled = false
    private var stableIDs: [String: String] = [:]

    init(engine: any LiveSpeakerAnalyzing, mode: MeetingMode, maximumPendingChunks: Int = 6) {
        self.engine = engine
        self.mode = mode
        self.maximumPendingChunks = max(1, maximumPendingChunks)
    }

    func updates() -> AsyncStream<LiveSpeakerBatch> {
        continuation?.finish()
        let pair = AsyncStream<LiveSpeakerBatch>.makeStream()
        guard !cancelled else {
            pair.continuation.finish()
            return pair.stream
        }
        continuation = pair.continuation
        return pair.stream
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) {
        guard !cancelled, !samples.isEmpty, startingAt.isFinite, startingAt >= 0 else { return }
        if pending.count == maximumPendingChunks {
            // Drop an obsolete preview, never recording or transcription data.
            // Whole-meeting finalization reconciles any skipped preview range.
            pending.removeFirst()
        }
        pending.append(MeetingAudioSampleChunk(samples: samples, startingAt: startingAt))
        guard worker == nil else { return }
        worker = Task(priority: .utility) { await processPending() }
    }

    func cancel() {
        cancelled = true
        worker?.cancel()
        worker = nil
        pending.removeAll()
        stableIDs.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func processPending() async {
        defer { worker = nil }
        while !cancelled, !Task.isCancelled, !pending.isEmpty {
            let chunk = pending.removeFirst()
            do {
                let intervals = try await engine.analyze(samples: chunk.samples, startingAt: chunk.startingAt)
                guard !cancelled, !Task.isCancelled else { return }
                let end = chunk.startingAt + Double(chunk.samples.count) / 16_000
                let valid = intervals.filter {
                    !$0.rawSpeakerID.isEmpty && $0.startTime.isFinite && $0.endTime.isFinite
                        && $0.endTime > $0.startTime && $0.endTime > chunk.startingAt
                        && $0.startTime < end
                }.sorted { $0.startTime < $1.startTime }
                let mapped = valid.map { interval -> SpeakerInterval in
                    if stableIDs[interval.rawSpeakerID] == nil {
                        let prefix = mode == .online ? "speaker" : "room"
                        stableIDs[interval.rawSpeakerID] = "\(prefix)-\(stableIDs.count + 1)"
                    }
                    return SpeakerInterval(
                        rawSpeakerID: stableIDs[interval.rawSpeakerID]!,
                        startTime: max(chunk.startingAt, interval.startTime),
                        endTime: min(end, interval.endTime)
                    )
                }
                continuation?.yield(LiveSpeakerBatch(
                    startTime: chunk.startingAt, endTime: end,
                    source: mode == .online ? .mixed : .room, intervals: mapped
                ))
            } catch {
                if !cancelled, !Task.isCancelled, !(error is CancellationError) {
                    continuation?.yield(LiveSpeakerBatch(
                        startTime: chunk.startingAt,
                        endTime: chunk.startingAt + Double(chunk.samples.count) / 16_000,
                        source: mode == .online ? .mixed : .room, intervals: [],
                        failureCode: "speaker_live_preview_failed"
                    ))
                }
                // Preview failure must not abort capture/transcription. End
                // this session's worker instead of repeatedly loading models;
                // the independent final pass reports persistent model errors.
                cancel()
                return
            }
        }
    }
}

private actor FluidAudioLiveSpeakerEngine: LiveSpeakerAnalyzing {
    private let modelsDirectory: URL
    private var manager: DiarizerManager?

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    func analyze(samples: [Float], startingAt: TimeInterval) async throws -> [SpeakerInterval] {
        try Task.checkCancellation()
        if manager == nil {
            // Streaming and offline models have different tensor contracts.
            // A separate app-owned cache keeps SDK recovery from replacing the
            // already installed offline diarization models.
            let models = try await DiarizerModels.load(from: modelsDirectory)
            try Task.checkCancellation()
            let created = DiarizerManager()
            created.initialize(models: models)
            manager = created
        }
        guard let manager else { throw SpeakerDiarizationError.modelPreparationFailed }
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000, atTime: startingAt)
        try Task.checkCancellation()
        return result.segments.map {
            SpeakerInterval(rawSpeakerID: $0.speakerId,
                            startTime: Double($0.startTimeSeconds), endTime: Double($0.endTimeSeconds))
        }
    }
}
