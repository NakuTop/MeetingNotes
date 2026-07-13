import AVFoundation
import XCTest
@testable import MeetingNotes

final class PCMConverterTests: XCTestCase {
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
        XCTAssertTrue(overloadedOutput.samples.allSatisfy { (-1...1).contains($0) })
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
