import ScreenCaptureKit
import XCTest
@testable import MeetingNotes

final class ScreenAudioCaptureConfigurationTests: XCTestCase {
    func testCapturesOnlySystemAndMicrophoneAudio() {
        let configuration = ScreenAudioCaptureConfiguration.makeStreamConfiguration()

        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 16_000)
        XCTAssertEqual(configuration.channelCount, 1)
        XCTAssertEqual(
            ScreenAudioCaptureConfiguration.registeredOutputTypes,
            [.audio, .microphone]
        )
        XCTAssertFalse(
            ScreenAudioCaptureConfiguration.registeredOutputTypes.contains(.screen)
        )
    }
}
