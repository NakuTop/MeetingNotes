import Accelerate
import Foundation

enum SpeakerSourceEvidence: String, Codable, Sendable {
    case microphoneDominant, systemDominant, mixed, possibleEcho

    var explanation: String {
        switch self {
        case .microphoneDominant: "麦克风音轨更强；不等同于已确认是本人。"
        case .systemDominant: "系统音轨更强；不等同于已确认远端姓名。"
        case .mixed: "两路音轨均有声音，来源待核对。"
        case .possibleEcho: "两路音轨的波形高度相似，可能存在回声；未自动合并说话人或删除文字。"
        }
    }
}

protocol OnlineSpeakerSourceReviewing: Sendable {
    func review(meetingID: UUID, drafts: [AttributedTranscriptDraft]) async throws
        -> [AttributedTranscriptDraft]
}

struct OnlineSpeakerSourceReviewer: OnlineSpeakerSourceReviewing {
    let reader: any MeetingTrackAudioReading

    private struct Observation {
        let start: Double
        let end: Double
        let evidence: SpeakerSourceEvidence
    }

    func review(meetingID: UUID, drafts: [AttributedTranscriptDraft]) async throws
        -> [AttributedTranscriptDraft]
    {
        guard !drafts.isEmpty else { return drafts }
        do {
            var microphone = try await reader.chunks(meetingID: meetingID, track: .microphone)
                .makeAsyncIterator()
            var system = try await reader.chunks(meetingID: meetingID, track: .system)
                .makeAsyncIterator()
            var mic = try await microphone.next()
            var sys = try await system.next()
            var observations: [Observation] = []
            // Hold only two reader chunks; retained observations contain no
            // audio samples. Reader timeline/identity checks remain in force.
            while let left = mic, let right = sys {
                try Task.checkCancellation()
                guard left.startingAt.isFinite, right.startingAt.isFinite,
                    left.startingAt >= 0, right.startingAt >= 0
                else { return drafts }
                let micEnd = left.startingAt + Double(left.samples.count) / 16_000
                let sysEnd = right.startingAt + Double(right.samples.count) / 16_000
                var start = max(left.startingAt, right.startingAt)
                let end = min(micEnd, sysEnd)
                while end - start >= 0.25 {
                    try Task.checkCancellation()
                    let stop = min(end, start + 1)
                    let count = Int(((stop - start) * 16_000).rounded(.down))
                    let a = Int(((start - left.startingAt) * 16_000).rounded())
                    let b = Int(((start - right.startingAt) * 16_000).rounded())
                    let length = min(count, left.samples.count - a, right.samples.count - b)
                    guard a >= 0, b >= 0, length > 0, observations.count < 172_800 else {
                        return drafts
                    }
                    if let evidence = Self.classify(
                        microphone: left.samples[a..<(a + length)],
                        system: right.samples[b..<(b + length)])
                    {
                        observations.append(
                            Observation(start: start, end: stop, evidence: evidence))
                    }
                    start = stop
                }
                if micEnd <= sysEnd { mic = try await microphone.next() }
                if sysEnd <= micEnd { sys = try await system.next() }
            }
            return drafts.map { draft in
                var result = draft
                result.sourceEvidence = Self.evidence(
                    for: draft.transcript, observations: observations)
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Advisory only. A missing historical source track must not erase
            // an otherwise usable master diarization or restart transcription.
            return drafts
        }
    }

    static func classify(microphone: ArraySlice<Float>, system: ArraySlice<Float>)
        -> SpeakerSourceEvidence?
    {
        guard !microphone.isEmpty, microphone.count == system.count,
            microphone.allSatisfy(\.isFinite), system.allSatisfy(\.isFinite)
        else { return nil }
        let micRMS = sqrt(
            microphone.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(microphone.count))
        let sysRMS = sqrt(
            system.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(system.count))
        guard max(micRMS, sysRMS) >= 0.002 else { return nil }
        if micRMS >= 3.2 * max(sysRMS, 0.0001) { return .microphoneDominant }
        if sysRMS >= 3.2 * max(micRMS, 0.0001) { return .systemDominant }
        // Diagnostic-only 500 Hz block averages; never fed to Whisper, never
        // used to suppress audio or merge identities. Correlation is evidence
        // of similarity, not proof that either track belongs to a named person.
        let a = blockAverages(microphone)
        let b = blockAverages(system)
        if a.count >= 250 {
            for lag in stride(from: -100, through: 100, by: 10) {
                if correlation(a, b, lag: lag) >= 0.96 { return .possibleEcho }
            }
        }
        return .mixed
    }

    private static func blockAverages(_ samples: ArraySlice<Float>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(samples.count / 32)
        var sum: Float = 0
        var count = 0
        for sample in samples {
            sum += sample
            count += 1
            if count == 32 {
                result.append(sum / 32)
                count = 0
                sum = 0
            }
        }
        return result
    }

    private static func correlation(_ a: [Float], _ b: [Float], lag: Int) -> Float {
        let offsetA = max(0, lag)
        let offsetB = max(0, -lag)
        let count = min(a.count - offsetA, b.count - offsetB)
        guard count >= 150 else { return 0 }
        return a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                guard let x = left.baseAddress?.advanced(by: offsetA),
                    let y = right.baseAddress?.advanced(by: offsetB)
                else { return 0 }
                var sx: Float = 0
                var sy: Float = 0
                var xx: Float = 0
                var yy: Float = 0
                var xy: Float = 0
                let n = vDSP_Length(count)
                vDSP_sve(x, 1, &sx, n)
                vDSP_sve(y, 1, &sy, n)
                vDSP_svesq(x, 1, &xx, n)
                vDSP_svesq(y, 1, &yy, n)
                vDSP_dotpr(x, 1, y, 1, &xy, n)
                let vx = max(0, xx - sx * sx / Float(count))
                let vy = max(0, yy - sy * sy / Float(count))
                guard vx > 0.000001, vy > 0.000001 else { return 0 }
                return abs((xy - sx * sy / Float(count)) / sqrt(vx * vy))
            }
        }
    }

    private static func evidence(for draft: TranscriptDraft, observations: [Observation])
        -> SpeakerSourceEvidence?
    {
        guard draft.startTime.isFinite, draft.endTime.isFinite, draft.endTime > draft.startTime
        else { return nil }
        var low = 0
        var high = observations.count
        while low < high {
            let middle = (low + high) / 2
            if observations[middle].end <= draft.startTime {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var weights: [SpeakerSourceEvidence: Double] = [:]
        var cursor = low
        while cursor < observations.count, observations[cursor].start < draft.endTime {
            let observation = observations[cursor]
            weights[observation.evidence, default: 0] += max(
                0, min(draft.endTime, observation.end) - max(draft.startTime, observation.start))
            cursor += 1
        }
        let total = weights.values.reduce(0, +)
        guard total >= 0.6 * (draft.endTime - draft.startTime),
            let best = weights.max(by: { $0.value < $1.value })
        else { return nil }
        return best.value >= total * 0.7 ? best.key : .mixed
    }
}
