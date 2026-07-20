import AVFoundation
import XCTest
@testable import MeetingNotes

final class RealtimeAudioMixerTests: XCTestCase {
    func testUsesPlaybackSampleRateForOnlineStorage() {
        XCTAssertEqual(
            RealtimeAudioMixer.sampleRate,
            PCMConverter.playbackSampleRate
        )
    }

    func testUsesTwentyMillisecondWindowsAtPlaybackRate() async throws {
        let mixer = RealtimeAudioMixer(holdbackWindowCount: 0)

        let emitted = try await mixer.ingest(
            frame(samples: Array(repeating: 0.1, count: 960)),
            source: .microphone
        )

        let window = try XCTUnwrap(emitted.first)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(window.samples.count, 960)
    }

    func testPreservesSystemSignalWhileAddingAudibleMicrophone() async throws {
        let mixer = RealtimeAudioMixer(windowSampleCount: 4)

        let first = try await mixer.ingest(
            frame(samples: [0.2, 0.4, -0.2, -0.4]),
            source: .microphone
        )
        let second = try await mixer.ingest(
            frame(samples: [0.6, 0.2, -0.6, -0.2]),
            source: .system
        )

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        assertSamples(second[0].samples, equalTo: [0.8, 0.6, -0.8, -0.6])
    }

    func testDoesNotAmplifyMicrophoneNoiseWhilePreservingSystemAudio() async throws {
        let mixer = RealtimeAudioMixer(windowSampleCount: 4)

        _ = try await mixer.ingest(
            frame(samples: [0.003, -0.003, 0.003, -0.003]),
            source: .microphone
        )
        let emitted = try await mixer.ingest(
            frame(samples: [0.4, 0.3, -0.4, -0.3]),
            source: .system
        )

        XCTAssertEqual(emitted.count, 1)
        assertSamples(
            emitted[0].samples,
            equalTo: [0.403, 0.297, -0.397, -0.303]
        )
    }

    func testPreservesQuietMicrophoneWhenSystemAudioIsSilent() async throws {
        let mixer = RealtimeAudioMixer(windowSampleCount: 4)

        _ = try await mixer.ingest(
            frame(samples: [0.003, -0.003, 0.002, -0.002]),
            source: .microphone
        )
        let emitted = try await mixer.ingest(
            frame(samples: [0, 0, 0, 0]),
            source: .system
        )

        XCTAssertEqual(emitted.count, 1)
        assertSamples(
            emitted[0].samples,
            equalTo: [0.003, -0.003, 0.002, -0.002]
        )
    }

    func testPreserveAmplitudeConverterThenMixerDoesNotRaiseRawMicNoise() async throws {
        let converter = PCMConverter(
            outputSampleRate: RealtimeAudioMixer.sampleRate,
            amplitudePolicy: .preserveAmplitude
        )
        let input = try makeMonoBuffer(samples: [
            0.003, -0.003, 0.003, -0.003,
        ])
        let converted = try converter.convert(input, timestamp: 0)
        let mixer = RealtimeAudioMixer(
            windowSampleCount: converted.samples.count
        )

        _ = try await mixer.ingest(converted, source: .microphone)
        let emitted = try await mixer.ingest(
            frame(samples: Array(
                repeating: 0.4,
                count: converted.samples.count
            )),
            source: .system
        )

        let mixed = try XCTUnwrap(emitted.first)
        XCTAssertEqual(mixed.samples.count, converted.samples.count)
        XCTAssertEqual(
            converted.samples.map(abs).max() ?? 0,
            0.003,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            mixed.samples.map { abs($0 - 0.4) }.max() ?? 0,
            0.003,
            accuracy: 0.000_001
        )
    }

    func testLimitsOnlyCombinedWindowsThatWouldClip() async throws {
        let mixer = RealtimeAudioMixer(windowSampleCount: 4)
        _ = try await mixer.ingest(
            frame(samples: [0.7, -0.7, 0.2, -0.2]),
            source: .microphone
        )
        let emitted = try await mixer.ingest(
            frame(samples: [0.7, -0.7, 0.2, -0.2]),
            source: .system
        )

        let frame = try XCTUnwrap(emitted.first)
        XCTAssertEqual(
            try XCTUnwrap(frame.samples.map(abs).max()),
            0.98,
            accuracy: 0.000_001
        )
        XCTAssertEqual(frame.samples[2], 0.28, accuracy: 0.000_001)
        XCTAssertEqual(frame.samples[3], -0.28, accuracy: 0.000_001)
    }

    func testKeepsSingleAvailableSource() async throws {
        let singleSourceMixer = RealtimeAudioMixer(
            windowSampleCount: 4,
            holdbackWindowCount: 1
        )

        let emitted = try await singleSourceMixer.ingest(
            frame(samples: [0.1, 0.2, 0.3, 0.4, -0.1, -0.2, -0.3, -0.4]),
            source: .microphone
        )
        let flushed = await singleSourceMixer.flush()

        XCTAssertEqual(emitted.count, 1)
        assertSamples(emitted[0].samples, equalTo: [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(flushed.count, 1)
        assertSamples(flushed[0].samples, equalTo: [-0.1, -0.2, -0.3, -0.4])
    }

    func testLeavesSingleSourceWindowUnchangedWhenPeakExceedsLimit() async throws {
        let mixer = RealtimeAudioMixer(
            windowSampleCount: 4,
            holdbackWindowCount: 0
        )

        let emitted = try await mixer.ingest(
            frame(samples: [2, -2, 4, -4]),
            source: .microphone
        )

        let frame = try XCTUnwrap(emitted.first)
        assertSamples(frame.samples, equalTo: [2, -2, 4, -4])
    }

    func testAlignsJitteredStartsIntoFixedWindows() async throws {
        let mixer = RealtimeAudioMixer(
            windowSampleCount: 4,
            holdbackWindowCount: 1
        )
        _ = try await mixer.ingest(
            frame(samples: [1, 1, 1, 1]),
            source: .system
        )

        let firstWindow = try await mixer.ingest(
            frame(
                timestamp: 2 / RealtimeAudioMixer.sampleRate,
                samples: [0, 0, 0, 0]
            ),
            source: .microphone
        )
        let secondIngest = try await mixer.ingest(
            frame(
                timestamp: 4 / RealtimeAudioMixer.sampleRate,
                samples: [1, 1, 1, 1]
            ),
            source: .system
        )
        let remainder = await mixer.flush()

        XCTAssertEqual(firstWindow.count, 1)
        XCTAssertTrue(secondIngest.isEmpty)
        XCTAssertEqual(firstWindow[0].timestamp, 0, accuracy: 0.000_001)
        assertSamples(firstWindow[0].samples, equalTo: [0.98, 0.98, 0.98, 0.98])
        XCTAssertEqual(remainder.count, 1)
        XCTAssertEqual(
            remainder[0].timestamp,
            4 / RealtimeAudioMixer.sampleRate,
            accuracy: 0.000_001
        )
        assertSamples(remainder[0].samples, equalTo: [0.98, 0.98, 0.98, 0.98])
    }

    private func frame(
        timestamp: TimeInterval = 0,
        samples: [Float]
    ) -> CapturedAudioFrame {
        CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: RealtimeAudioMixer.sampleRate,
            channelCount: 1,
            samples: samples
        )
    }

    private func makeMonoBuffer(
        samples: [Float]
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: RealtimeAudioMixer.sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }

    private func assertSamples(
        _ actual: [Float],
        equalTo expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualSample, expectedSample) in zip(actual, expected) {
            XCTAssertEqual(
                actualSample,
                expectedSample,
                accuracy: 0.000_001,
                file: file,
                line: line
            )
        }
    }
}
