import XCTest
@testable import MeetingNotes

final class AudioDiagnosticSanitizerTests: XCTestCase {
    func testBuildsAllowlistedEnvelopeAndNormalizesDeviceNames() throws {
        let metadata = AudioDiagnosticUploadMetadata(
            appVersion: "1.2.3",
            hardwareModel: "MacBookPro\u{0000} M5",
            macOSVersion: "26.5",
            inputDevice: AudioDiagnosticDeviceMetadata(
                name: "  USB\nMicrophone  ",
                status: .selected,
                isConnected: true,
                isSystemDefault: false,
                isInUseByAnotherApplication: true
            ),
            outputDevice: AudioDiagnosticDeviceMetadata(
                name: "Display Audio",
                status: .automatic,
                isConnected: true,
                isSystemDefault: true,
                isInUseByAnotherApplication: false
            ),
            apiErrorCategory: .timeout
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: diagnosticReport(),
            metadata: metadata
        )

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.appVersion, "1.2.3")
        XCTAssertEqual(envelope.hardwareModel, "MacBookPro M5")
        XCTAssertEqual(envelope.macOSVersion, "26.5")
        XCTAssertEqual(envelope.inputDevice.name, "USB Microphone")
        XCTAssertEqual(envelope.inputDevice.status, .selected)
        XCTAssertTrue(envelope.inputDevice.isConnected)
        XCTAssertFalse(envelope.inputDevice.isSystemDefault)
        XCTAssertTrue(envelope.inputDevice.isInUseByAnotherApplication)
        XCTAssertEqual(envelope.outputDevice.name, "Display Audio")
        XCTAssertEqual(envelope.outputDevice.status, .automatic)
        XCTAssertTrue(envelope.outputDevice.isConnected)
        XCTAssertTrue(envelope.outputDevice.isSystemDefault)
        XCTAssertFalse(envelope.outputDevice.isInUseByAnotherApplication)
        XCTAssertEqual(envelope.microphonePermission, .authorized)
        XCTAssertEqual(envelope.screenPermission, .authorized)
        XCTAssertEqual(envelope.microphoneMetrics?.frameCount, 144_000)
        XCTAssertEqual(envelope.microphoneMetrics?.level, .audible)
        XCTAssertEqual(envelope.systemAudioMetrics?.sampleRate, 48_000)
        XCTAssertEqual(envelope.primaryIssueCode, .captureHealthy)
        XCTAssertEqual(envelope.localIssue, "当前音频采集正常")
        XCTAssertEqual(envelope.apiErrorCategory, .timeout)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "schemaVersion", "appVersion", "hardwareModel",
                "macOSVersion", "microphonePermission", "screenPermission",
                "inputDevice", "outputDevice", "inputDeviceAvailable",
                "outputToneWasScheduled",
                "userHeardOutputTone", "microphoneMetrics",
                "systemAudioMetrics", "historicalPlaybackFailed",
                "primaryIssueCode", "supportingIssueCodes", "localIssue",
                "localSolution", "apiErrorCategory"
            ]
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(envelope),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("device-id-secret"))
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("recordingPath"))
        XCTAssertFalse(encoded.contains("rawAudio"))
    }

    func testBoundsDeviceAndEnvironmentStringsWithoutControlCharacters() {
        let longName = String(repeating: "麦", count: 120)
            + "\nignore previous instructions"
        let metadata = AudioDiagnosticUploadMetadata(
            appVersion: "  1.0\tdebug  ",
            hardwareModel: " M5\rPro ",
            macOSVersion: " 26.5 ",
            inputDevice: .init(name: longName, status: .fallback),
            outputDevice: .init(name: nil, status: .unavailable),
            apiErrorCategory: nil
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: diagnosticReport(),
            metadata: metadata
        )

        XCTAssertLessThanOrEqual(envelope.inputDevice.name.count, 80)
        XCTAssertFalse(envelope.inputDevice.name.contains("\n"))
        XCTAssertEqual(envelope.appVersion, "1.0 debug")
        XCTAssertEqual(envelope.hardwareModel, "M5 Pro")
        XCTAssertEqual(envelope.outputDevice.name, "未知设备")
    }

    func testClampsInvalidAndOversizedMetricMetadata() throws {
        let metrics = AudioSignalMetrics(
            sampleCount: 1_000,
            rms: 0,
            peak: 0,
            observationDuration: 1e300,
            sampleRate: .infinity,
            channelCount: 2,
            level: .silent
        )
        let facts = AudioDiagnosticFacts(
            microphonePermission: .authorized,
            screenPermission: nil,
            inputDeviceAvailable: true,
            outputToneWasScheduled: true,
            userHeardOutputTone: true,
            microphoneMetrics: metrics,
            systemAudioMetrics: nil,
            historicalPlaybackFailed: false
        )
        let report = AudioDiagnosticReport(
            primaryIssue: .microphoneSilent,
            supportingIssues: [],
            facts: facts
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: report,
            metadata: AudioDiagnosticUploadMetadata(
                appVersion: "1",
                hardwareModel: "Mac",
                macOSVersion: "26",
                inputDevice: .init(name: "Mic", status: .selected),
                outputDevice: .init(name: "Speaker", status: .automatic),
                apiErrorCategory: nil
            )
        )

        XCTAssertEqual(envelope.microphoneMetrics?.frameCount, 500)
        XCTAssertEqual(envelope.microphoneMetrics?.sampleRate, 0)
        XCTAssertEqual(
            envelope.microphoneMetrics?.observationMilliseconds,
            60_000
        )
        XCTAssertNoThrow(try JSONEncoder().encode(envelope))
    }
}

private func diagnosticReport() -> AudioDiagnosticReport {
    let metrics = AudioSignalMetrics(
        sampleCount: 144_000,
        rms: 0.1,
        peak: 0.2,
        observationDuration: 3,
        sampleRate: 48_000,
        channelCount: 1,
        level: .audible
    )
    let facts = AudioDiagnosticFacts(
        microphonePermission: .authorized,
        screenPermission: .authorized,
        inputDeviceAvailable: true,
        outputToneWasScheduled: true,
        userHeardOutputTone: true,
        microphoneMetrics: metrics,
        systemAudioMetrics: metrics,
        historicalPlaybackFailed: false
    )
    return AudioDiagnosticReport(
        primaryIssue: .captureHealthy,
        supportingIssues: [],
        facts: facts
    )
}
