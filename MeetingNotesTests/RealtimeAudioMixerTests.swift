import XCTest
@testable import MeetingNotes

final class RealtimeAudioMixerTests: XCTestCase {
    func testAveragesAlignedMicrophoneAndSystemSamples() async throws {
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
        assertSamples(second[0].samples, equalTo: [0.4, 0.3, -0.4, -0.3])
    }

    func testKeepsSingleAvailableSourceAndClampsOverload() async throws {
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

        let clippingMixer = RealtimeAudioMixer(windowSampleCount: 4)
        _ = try await clippingMixer.ingest(
            frame(samples: [2, -2, 4, -4]),
            source: .microphone
        )
        let clipped = try await clippingMixer.ingest(
            frame(samples: [2, -2, 4, -4]),
            source: .system
        )
        assertSamples(clipped[0].samples, equalTo: [1, -1, 1, -1])
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
                timestamp: 2 / 16_000,
                samples: [0, 0, 0, 0]
            ),
            source: .microphone
        )
        let secondIngest = try await mixer.ingest(
            frame(
                timestamp: 4 / 16_000,
                samples: [1, 1, 1, 1]
            ),
            source: .system
        )
        let remainder = await mixer.flush()

        XCTAssertEqual(firstWindow.count, 1)
        XCTAssertTrue(secondIngest.isEmpty)
        XCTAssertEqual(firstWindow[0].timestamp, 0, accuracy: 0.000_001)
        assertSamples(firstWindow[0].samples, equalTo: [1, 1, 0.5, 0.5])
        XCTAssertEqual(remainder.count, 1)
        XCTAssertEqual(remainder[0].timestamp, 4 / 16_000, accuracy: 0.000_001)
        assertSamples(remainder[0].samples, equalTo: [0.5, 0.5, 1, 1])
    }

    private func frame(
        timestamp: TimeInterval = 0,
        samples: [Float]
    ) -> CapturedAudioFrame {
        CapturedAudioFrame(
            timestamp: timestamp,
            sampleRate: 16_000,
            channelCount: 1,
            samples: samples
        )
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
