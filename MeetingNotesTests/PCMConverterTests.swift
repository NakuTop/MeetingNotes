import AVFoundation
import XCTest
@testable import MeetingNotes

final class PCMConverterTests: XCTestCase {
    func testStreamingChunksDoNotAccumulateResamplingRoundingDrift() throws {
        let converter = PCMConverter()
        let chunkFrameCount: AVAudioFrameCount = 4_096
        let chunkCount = 12
        var convertedSampleCount = 0

        for chunkIndex in 0..<chunkCount {
            let input = try makeBuffer(frameCount: chunkFrameCount) {
                frame,
                _ in
                let globalFrame = chunkIndex * Int(chunkFrameCount) + frame
                return 0.2 * sin(
                    Float(globalFrame) * 2 * .pi * 440 / 48_000
                )
            }
            convertedSampleCount += try converter.convert(
                input,
                timestamp: Double(chunkIndex) * Double(chunkFrameCount) / 48_000
            ).samples.count
        }

        let expectedSampleCount = Int(
            (Double(chunkFrameCount) * Double(chunkCount) / 3).rounded()
        )
        XCTAssertEqual(
            convertedSampleCount,
            expectedSampleCount,
            accuracy: 1,
            "连续重采样应保留小数帧累计，不能每个 tap 都向上取整"
        )
    }

    func testRaisesQuietSpeechToUsefulLevelWithoutClipping() throws {
        let quietSpeechPeak = Float(
            pow(10, -42.8 / 20) * sqrt(2.0)
        )
        let input = try makeBuffer(frameCount: 48_000) { frame, _ in
            quietSpeechPeak * sin(Float(frame) * 2 * .pi * 220 / 48_000)
        }

        let output = try PCMConverter().convert(input, timestamp: 0)

        let rms = sqrt(
            output.samples.reduce(0.0) { $0 + Double($1 * $1) }
                / Double(output.samples.count)
        )
        let decibels = 20 * log10(rms)
        XCTAssertGreaterThanOrEqual(decibels, -27)
        XCTAssertLessThanOrEqual(
            output.samples.map { abs($0) }.max() ?? 0,
            0.95 + Float.ulpOfOne
        )
    }

    func testResetStartsTheNextCaptureWithFreshResamplingState() throws {
        let converter = PCMConverter()
        let input = try makeBuffer(frameCount: 4_096) { frame, _ in
            0.2 * sin(Float(frame) * 2 * .pi * 330 / 48_000)
        }

        let firstCapture = try converter.convert(input, timestamp: 0)
        converter.reset()
        let secondCapture = try converter.convert(input, timestamp: 0)

        XCTAssertEqual(secondCapture.samples.count, firstCapture.samples.count)
        XCTAssertEqual(
            secondCapture.samples,
            firstCapture.samples,
            "新会话不应携带上一次重采样器的滤波历史"
        )
    }

    func testNonFiniteInputNeverEscapesAsInvalidOrClippedSamples() throws {
        let input = try makeBuffer(frameCount: 4_800) { frame, _ in
            switch frame % 3 {
            case 0: .nan
            case 1: .infinity
            default: -.infinity
            }
        }

        let output = try PCMConverter().convert(input, timestamp: 0)

        XCTAssertTrue(output.samples.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(
            output.samples.map { abs($0) }.max() ?? 0,
            0.95 + Float.ulpOfOne
        )
    }

    func testConverts48kStereoTo16kMonoWithinOneOutputFrameOfDuration() throws {
        let input = try makeBuffer(frameCount: 48_000) { frame, channel in
            let amplitude: Float = channel == 0 ? 0.8 : 0.4
            return amplitude * sin(Float(frame) * 2 * .pi * 440 / 48_000)
        }

        let output = try PCMConverter().convert(input, timestamp: 12.5)

        XCTAssertEqual(output.timestamp, 12.5, accuracy: 0.000_001)
        XCTAssertEqual(output.sampleRate, 16_000, accuracy: 0.001)
        XCTAssertEqual(output.channelCount, 1)
        let inputDuration = Double(input.frameLength) / input.format.sampleRate
        let outputDuration = Double(output.samples.count) / output.sampleRate
        XCTAssertEqual(outputDuration, inputDuration, accuracy: 1 / 16_000)
        XCTAssertTrue(output.samples.allSatisfy { (-1...1).contains($0) })
        XCTAssertTrue(output.samples.contains { abs($0) > 0.01 })
    }

    func testSilenceRemainsSilentAndOverloadIsClamped() throws {
        let silentInput = try makeBuffer(frameCount: 4_800) { _, _ in 0 }
        let silentOutput = try PCMConverter().convert(silentInput, timestamp: 0)

        XCTAssertFalse(silentOutput.samples.isEmpty)
        XCTAssertTrue(silentOutput.samples.allSatisfy { abs($0) < 0.000_001 })

        let overloadedInput = try makeBuffer(frameCount: 4_800) { _, _ in 4 }
        let overloadedOutput = try PCMConverter().convert(
            overloadedInput,
            timestamp: 0
        )
        XCTAssertTrue(
            overloadedOutput.samples.allSatisfy { (-0.95...0.95).contains($0) }
        )
    }

    private func makeBuffer(
        frameCount: AVAudioFrameCount,
        sample: (Int, Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = sample(frame, channel)
            }
        }
        return buffer
    }
}
