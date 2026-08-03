import XCTest
@testable import MeetingNotes

@MainActor
final class PrivacySettingsOpenerTests: XCTestCase {
    func testMicrophoneOpensMicrophonePrivacyPane() throws {
        var openedURLs: [URL] = []
        let opener = PrivacySettingsOpener { url in
            openedURLs.append(url)
            return true
        }

        try opener.open(.microphone)

        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ]
        )
    }

    func testScreenRecordingOpensScreenCapturePrivacyPane() throws {
        var openedURLs: [URL] = []
        let opener = PrivacySettingsOpener { url in
            openedURLs.append(url)
            return true
        }

        try opener.open(.screenRecording)

        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ]
        )
    }

    func testUnknownDestinationReturnsLocalErrorWithoutOpeningURL() {
        var openedURLs: [URL] = []
        let opener = PrivacySettingsOpener { url in
            openedURLs.append(url)
            return true
        }

        XCTAssertThrowsError(try opener.open(.unknown)) { error in
            XCTAssertEqual(
                error as? PrivacySettingsOpenError,
                .destinationUnavailable
            )
            XCTAssertEqual(
                error.localizedDescription,
                "无法定位对应的 macOS 隐私设置，请手动打开“系统设置 > 隐私与安全性”。"
            )
        }
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testWorkspaceRejectionReturnsLocalError() {
        let opener = PrivacySettingsOpener(openURL: { _ in false })

        XCTAssertThrowsError(try opener.open(.microphone)) { error in
            XCTAssertEqual(
                error as? PrivacySettingsOpenError,
                .openFailed
            )
        }
    }
}
