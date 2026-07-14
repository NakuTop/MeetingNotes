import Foundation

struct TranscriptionQueueSnapshot: Equatable, Sendable {
    let waitingCount: Int
    let isProcessing: Bool
    let failedCount: Int

    static let idle = TranscriptionQueueSnapshot(
        waitingCount: 0,
        isProcessing: false,
        failedCount: 0
    )
}

actor TranscriptionQueue {
    private struct Chunk: Sendable {
        let samples: [Float]
        let startingAt: TimeInterval
    }

    private let service: any TranscriptionService
    private let merger: TranscriptMerger
    private var waiting: [Chunk] = []
    private var failed: [Chunk] = []
    private var completed: [TranscriptDraft] = []
    private var isPrepared = false
    private var isProcessing = false
    private var workerTask: Task<Void, Never>?

    init(
        service: any TranscriptionService,
        merger: TranscriptMerger = TranscriptMerger()
    ) {
        self.service = service
        self.merger = merger
    }

    func enqueue(samples: [Float], startingAt: TimeInterval) {
        guard !samples.isEmpty else {
            return
        }
        waiting.append(Chunk(samples: samples, startingAt: startingAt))
        startWorkerIfNeeded()
    }

    func retryFailed() {
        guard !failed.isEmpty else {
            return
        }
        waiting.append(contentsOf: failed)
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

    func snapshot() -> TranscriptionQueueSnapshot {
        TranscriptionQueueSnapshot(
            waitingCount: waiting.count,
            isProcessing: isProcessing,
            failedCount: failed.count
        )
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
                failed.append(contentsOf: waiting)
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
            } catch {
                failed.append(chunk)
            }
            isProcessing = false
        }
        workerTask = nil
    }
}
