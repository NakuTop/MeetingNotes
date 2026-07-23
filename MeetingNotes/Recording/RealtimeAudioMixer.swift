import Foundation

enum RealtimeAudioSource: Equatable, Hashable, Sendable {
    case microphone
    case system
}

enum RealtimeAudioMixerError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Double)
    case unsupportedChannelCount(Int)
}

actor RealtimeAudioMixer {
    private struct Bucket {
        var microphoneSums: [Float]
        var microphoneCounts: [Int]
        var systemSums: [Float]
        var systemCounts: [Int]

        init(sampleCount: Int) {
            microphoneSums = Array(repeating: 0, count: sampleCount)
            microphoneCounts = Array(repeating: 0, count: sampleCount)
            systemSums = Array(repeating: 0, count: sampleCount)
            systemCounts = Array(repeating: 0, count: sampleCount)
        }

        mutating func add(
            _ sample: Float,
            at offset: Int,
            source: RealtimeAudioSource
        ) {
            switch source {
            case .microphone:
                microphoneSums[offset] += sample
                microphoneCounts[offset] += 1
            case .system:
                systemSums[offset] += sample
                systemCounts[offset] += 1
            }
        }

        func sourceSamples(
            for source: RealtimeAudioSource
        ) -> [Float] {
            let sums: [Float]
            let counts: [Int]
            switch source {
            case .microphone:
                sums = microphoneSums
                counts = microphoneCounts
            case .system:
                sums = systemSums
                counts = systemCounts
            }
            return sums.indices.map { index in
                guard counts[index] > 0 else { return 0 }
                return sums[index] / Float(counts[index])
            }
        }

        func mixedSamples(
            microphoneSamples: [Float],
            systemSamples: [Float]
        ) -> [Float] {
            let mixedSamples = zip(
                microphoneSamples,
                systemSamples
            ).map(+)
            let containsMicrophone = microphoneCounts.contains { $0 > 0 }
            let containsSystem = systemCounts.contains { $0 > 0 }
            guard containsMicrophone,
                  containsSystem,
                  let peak = mixedSamples.map(abs).max(),
                  peak > RealtimeAudioMixer.maximumMixedPeak else {
                return mixedSamples
            }
            let scale = RealtimeAudioMixer.maximumMixedPeak / peak
            return mixedSamples.map { $0 * scale }
        }
    }

    static let sampleRate = PCMConverter.playbackSampleRate
    private static let maximumMixedPeak: Float = 0.98

    private let windowSampleCount: Int
    private let holdbackSampleCount: Int
    private var buckets: [Int: Bucket] = [:]
    private var latestSampleBySource: [RealtimeAudioSource: Int] = [:]
    private var nextWindowIndex: Int?

    init(
        windowSampleCount: Int = 960,
        holdbackWindowCount: Int = 2
    ) {
        self.windowSampleCount = max(1, windowSampleCount)
        holdbackSampleCount = max(0, holdbackWindowCount) * max(1, windowSampleCount)
    }

    func ingest(
        _ frame: CapturedAudioFrame,
        source: RealtimeAudioSource
    ) throws -> [CapturedAudioPacket] {
        guard abs(frame.sampleRate - Self.sampleRate) < 0.001 else {
            throw RealtimeAudioMixerError.unsupportedSampleRate(frame.sampleRate)
        }
        guard frame.channelCount == 1 else {
            throw RealtimeAudioMixerError.unsupportedChannelCount(frame.channelCount)
        }
        guard !frame.samples.isEmpty else {
            return []
        }

        let startSample = Int((frame.timestamp * Self.sampleRate).rounded())
        var frameOffset = 0
        while frameOffset < frame.samples.count {
            let absoluteSample = startSample + frameOffset
            guard absoluteSample >= 0 else {
                frameOffset += 1
                continue
            }
            let windowIndex = absoluteSample / windowSampleCount
            let windowOffset = absoluteSample % windowSampleCount
            let sampleCount = min(
                windowSampleCount - windowOffset,
                frame.samples.count - frameOffset
            )
            if let nextWindowIndex, windowIndex < nextWindowIndex {
                frameOffset += sampleCount
                continue
            }
            var bucket = buckets.removeValue(forKey: windowIndex)
                ?? Bucket(sampleCount: windowSampleCount)
            for chunkOffset in 0..<sampleCount {
                bucket.add(
                    frame.samples[frameOffset + chunkOffset],
                    at: windowOffset + chunkOffset,
                    source: source
                )
            }
            buckets[windowIndex] = bucket
            if let current = nextWindowIndex {
                nextWindowIndex = min(current, windowIndex)
            } else {
                nextWindowIndex = windowIndex
            }
            frameOffset += sampleCount
        }

        let lastSample = startSample + frame.samples.count - 1
        latestSampleBySource[source] = max(
            latestSampleBySource[source] ?? lastSample,
            lastSample
        )
        return emitReadyWindows()
    }

    func flush() -> [CapturedAudioPacket] {
        guard let firstWindow = nextWindowIndex,
              let lastWindow = buckets.keys.max() else {
            reset()
            return []
        }
        var result: [CapturedAudioPacket] = []
        for windowIndex in firstWindow...lastWindow {
            if let packet = makePacket(windowIndex: windowIndex) {
                result.append(packet)
            }
        }
        reset()
        return result
    }

    private func emitReadyWindows() -> [CapturedAudioPacket] {
        guard let watermark = emissionWatermark() else {
            return []
        }
        var result: [CapturedAudioPacket] = []
        while let windowIndex = nextWindowIndex {
            let lastSampleInWindow = ((windowIndex + 1) * windowSampleCount) - 1
            guard lastSampleInWindow <= watermark else {
                break
            }
            if let packet = makePacket(windowIndex: windowIndex) {
                result.append(packet)
            }
            nextWindowIndex = windowIndex + 1
        }
        return result
    }

    private func emissionWatermark() -> Int? {
        let values = Array(latestSampleBySource.values)
        guard let maximum = values.max() else {
            return nil
        }
        if values.count == 1 {
            return maximum - holdbackSampleCount
        }
        let minimum = values.min() ?? maximum
        return max(minimum, maximum - holdbackSampleCount)
    }

    private func makePacket(
        windowIndex: Int
    ) -> CapturedAudioPacket? {
        guard let bucket = buckets.removeValue(forKey: windowIndex) else {
            return nil
        }
        let timestamp = Double(windowIndex * windowSampleCount) / Self.sampleRate
        let microphoneSamples = bucket.sourceSamples(for: .microphone)
        let systemSamples = bucket.sourceSamples(for: .system)
        let master = CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: Self.sampleRate,
            channelCount: 1,
            samples: bucket.mixedSamples(
                microphoneSamples: microphoneSamples,
                systemSamples: systemSamples
            )
        )
        return CapturedAudioPacket(
            master: master,
            sourceFrames: [
                .microphone: CapturedAudioFrame(
                    timestamp: timestamp,
                    sampleRate: Self.sampleRate,
                    channelCount: 1,
                    samples: microphoneSamples
                ),
                .system: CapturedAudioFrame(
                    timestamp: timestamp,
                    sampleRate: Self.sampleRate,
                    channelCount: 1,
                    samples: systemSamples
                ),
            ]
        )
    }

    private func reset() {
        buckets.removeAll(keepingCapacity: true)
        latestSampleBySource.removeAll(keepingCapacity: true)
        nextWindowIndex = nil
    }
}
