import Foundation

struct TranscriptionQueueSnapshot: Equatable, Sendable {
    let waitingCount: Int
    let isProcessing: Bool
    let failedCount: Int
    let deferredCount: Int

    init(
        waitingCount: Int,
        isProcessing: Bool,
        failedCount: Int,
        deferredCount: Int = 0
    ) {
        self.waitingCount = waitingCount
        self.isProcessing = isProcessing
        self.failedCount = failedCount
        self.deferredCount = deferredCount
    }

    static let idle = TranscriptionQueueSnapshot(
        waitingCount: 0,
        isProcessing: false,
        failedCount: 0,
        deferredCount: 0
    )
}

struct DeferredTranscriptionChunk: Equatable, Sendable {
    let startingAt: TimeInterval
    let sampleCount: Int
}

actor TranscriptionQueue {
    private struct Chunk: Sendable {
        let samples: [Float]
        let startingAt: TimeInterval
    }

    private let service: any TranscriptionService
    private let merger: TranscriptMerger
    private let maximumBufferedChunks: Int
    private var waiting: [Chunk] = []
    private var failed: [Chunk] = []
    private var deferred: [DeferredTranscriptionChunk] = []
    private var completed: [TranscriptDraft] = []
    private var isPrepared = false
    private var isProcessing = false
    private var workerTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<TranscriptDraft>.Continuation?

    init(
        service: any TranscriptionService,
        merger: TranscriptMerger = TranscriptMerger(),
        maximumBufferedChunks: Int = 8
    ) {
        self.service = service
        self.merger = merger
        self.maximumBufferedChunks = max(1, maximumBufferedChunks)
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) {
        guard !samples.isEmpty else {
            return
        }
        guard waiting.count < maximumBufferedChunks else {
            deferChunk(samples: samples, startingAt: startingAt)
            return
        }
        waiting.append(Chunk(samples: samples, startingAt: startingAt))
        startWorkerIfNeeded()
    }

    func retryFailed() {
        guard !failed.isEmpty else {
            return
        }
        for chunk in failed {
            if waiting.count < maximumBufferedChunks {
                waiting.append(chunk)
            } else {
                deferChunk(
                    samples: chunk.samples,
                    startingAt: chunk.startingAt
                )
            }
        }
        failed.removeAll(keepingCapacity: true)
        startWorkerIfNeeded()
    }

    func drain() async {
        while let workerTask {
            await workerTask.value
        }
    }

    func transcripts() -> [TranscriptDraft] {
        merger.merge(completed)
    }

    func updates() -> AsyncStream<TranscriptDraft> {
        updateContinuation?.finish()
        let pair = AsyncStream<TranscriptDraft>.makeStream()
        updateContinuation = pair.continuation
        return pair.stream
    }

    func finishUpdates() async {
        await drain()
        updateContinuation?.finish()
        updateContinuation = nil
    }

    func snapshot() -> TranscriptionQueueSnapshot {
        TranscriptionQueueSnapshot(
            waitingCount: waiting.count,
            isProcessing: isProcessing,
            failedCount: failed.count,
            deferredCount: deferred.count
        )
    }

    func deferredChunks() -> [DeferredTranscriptionChunk] {
        deferred
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else {
            return
        }
        workerTask = Task { await consumeWaitingChunks() }
    }

    private func consumeWaitingChunks() async {
        if !isPrepared {
            do {
                try await service.prepare()
                isPrepared = true
            } catch {
                for chunk in waiting {
                    retainFailedChunkOrDefer(chunk)
                }
                waiting.removeAll(keepingCapacity: true)
                workerTask = nil
                return
            }
        }

        while !waiting.isEmpty {
            let chunk = waiting.removeFirst()
            isProcessing = true
            do {
                let drafts = try await service.transcribe(
                    samples: chunk.samples,
                    startingAt: chunk.startingAt
                )
                completed.append(contentsOf: drafts)
                for draft in drafts {
                    updateContinuation?.yield(draft)
                }
            } catch {
                retainFailedChunkOrDefer(chunk)
            }
            isProcessing = false
        }
        workerTask = nil
    }

    private func retainFailedChunkOrDefer(_ chunk: Chunk) {
        if failed.count < maximumBufferedChunks {
            failed.append(chunk)
        } else {
            deferChunk(
                samples: chunk.samples,
                startingAt: chunk.startingAt
            )
        }
    }

    private func deferChunk(
        samples: [Float],
        startingAt: TimeInterval
    ) {
        deferred.append(
            DeferredTranscriptionChunk(
                startingAt: startingAt,
                sampleCount: samples.count
            )
        )
    }
}
