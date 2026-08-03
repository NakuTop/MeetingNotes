import Foundation

enum AudioLevelBand: String, Codable, CaseIterable, Sendable, Equatable {
    case noFrames
    case silent
    case veryLow
    case audible
}

struct AudioSignalMetrics: Sendable, Equatable {
    let sampleCount: Int
    let rms: Double
    let peak: Double
    let observationDuration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let level: AudioLevelBand
}

struct AudioSignalAccumulator: Sendable {
    private static let silentPeakThreshold = Double(Float(0.000_01))
    private static let veryLowRMSThreshold = Double(Float(0.003))

    private var sampleCount = 0
    private var sumOfSquares = 0.0
    private var peak = 0.0
    private var observationDuration: TimeInterval = 0
    private var sampleRate = 0.0
    private var channelCount = 0

    mutating func ingest(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int
    ) {
        guard sampleRate.isFinite,
              sampleRate > 0,
              channelCount > 0 else {
            return
        }

        for sample in samples {
            let finiteSample = sample.isFinite ? Double(sample) : 0
            sumOfSquares += finiteSample * finiteSample
            peak = max(peak, abs(finiteSample))
        }
        sampleCount += samples.count

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        let duration = Double(samples.count)
            / (sampleRate * Double(channelCount))
        if duration.isFinite {
            observationDuration += duration
        }
    }

    func snapshot() -> AudioSignalMetrics {
        let rms: Double
        if sampleCount == 0 {
            rms = 0
        } else {
            let meanSquare = sumOfSquares / Double(sampleCount)
            rms = meanSquare.isFinite
                ? sqrt(max(0, meanSquare))
                : Double.greatestFiniteMagnitude
        }

        return AudioSignalMetrics(
            sampleCount: sampleCount,
            rms: rms,
            peak: peak.isFinite ? peak : Double.greatestFiniteMagnitude,
            observationDuration: observationDuration.isFinite
                ? observationDuration
                : Double.greatestFiniteMagnitude,
            sampleRate: sampleRate,
            channelCount: channelCount,
            level: Self.level(
                sampleCount: sampleCount,
                rms: rms,
                peak: peak
            )
        )
    }

    private static func level(
        sampleCount: Int,
        rms: Double,
        peak: Double
    ) -> AudioLevelBand {
        if sampleCount == 0 {
            return .noFrames
        }
        if peak < silentPeakThreshold {
            return .silent
        }
        if rms < veryLowRMSThreshold {
            return .veryLow
        }
        return .audible
    }
}
