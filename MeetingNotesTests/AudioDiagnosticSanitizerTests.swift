import XCTest
@testable import MeetingNotes

final class AudioDiagnosticSanitizerTests: XCTestCase {
    func testBuildsAllowlistedEnvelope() throws {
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

        XCTAssertEqual(envelope.schemaVersion, 2)
        XCTAssertEqual(envelope.appVersion, "1.2.3")
        XCTAssertEqual(envelope.hardwareModel, "MacBookPro M5")
        XCTAssertEqual(envelope.macOSVersion, "26.5")
        XCTAssertEqual(envelope.inputDevice.status, .selected)
        XCTAssertTrue(envelope.inputDevice.isConnected)
        XCTAssertFalse(envelope.inputDevice.isSystemDefault)
        XCTAssertTrue(envelope.inputDevice.isInUseByAnotherApplication)
        XCTAssertEqual(envelope.outputDevice.status, .automatic)
        XCTAssertTrue(envelope.outputDevice.isConnected)
        XCTAssertTrue(envelope.outputDevice.isSystemDefault)
        XCTAssertFalse(envelope.outputDevice.isInUseByAnotherApplication)
        XCTAssertEqual(envelope.microphonePermission, .authorized)
        XCTAssertEqual(envelope.screenPermission, .authorized)
        XCTAssertEqual(envelope.microphoneMetrics?.frameCount, 144_000)
        XCTAssertEqual(envelope.microphoneMetrics?.level, .audible)
        XCTAssertEqual(envelope.systemAudioMetrics?.sampleRate, 48_000)
        XCTAssertEqual(envelope.microphoneTestOutcome, .succeeded)
        XCTAssertEqual(envelope.systemAudioTestOutcome, .succeeded)
        XCTAssertNil(envelope.diagnosticFailureStage)
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
                "microphoneTestOutcome", "systemAudioTestOutcome",
                "primaryIssueCode", "supportingIssueCodes", "localIssue",
                "localSolution", "apiErrorCategory"
            ]
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(envelope),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("diagnosticFailureStage"))
        XCTAssertFalse(encoded.contains("device-id-secret"))
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("recordingPath"))
        XCTAssertFalse(encoded.contains("rawAudio"))
    }

    func testOmitsDeviceNamesAndPrivateIdentifiersFromEncodedEnvelope() throws {
        let privateUsername = "private-user"
        let privateSerial = "C02PRIVATE1234"
        let privateDeviceUID = "coreaudio-uid-private"
        let privatePath = "/Users/private-user/recording.wav"
        let privateAudio = "private-audio-samples"
        let privateTranscript = "private-transcript-text"
        let privateAPIKey = "api-key-secret"
        let privateToken = "notion-token-secret"
        let privateRawError = "NSError-private-description"
        let inputDeviceName = [
            privateUsername, privateSerial, privateDeviceUID, privatePath
        ].joined(separator: " ")
        let outputDeviceName = [
            privateAudio, privateTranscript, privateAPIKey,
            privateToken, privateRawError
        ].joined(separator: " ")
        let metadata = AudioDiagnosticUploadMetadata(
            appVersion: "1.2.0",
            hardwareModel: "MacBookPro18,3",
            macOSVersion: "26.5",
            inputDevice: .init(
                name: inputDeviceName,
                status: .selected,
                isConnected: true
            ),
            outputDevice: .init(
                name: outputDeviceName,
                status: .automatic,
                isConnected: true,
                isSystemDefault: true
            ),
            apiErrorCategory: nil
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: diagnosticReport(),
            metadata: metadata
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let inputDevice = try XCTUnwrap(
            object["inputDevice"] as? [String: Any]
        )
        let outputDevice = try XCTUnwrap(
            object["outputDevice"] as? [String: Any]
        )
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(metadata.inputDevice.name, inputDeviceName)
        XCTAssertEqual(metadata.outputDevice.name, outputDeviceName)
        XCTAssertNil(inputDevice["name"])
        XCTAssertNil(outputDevice["name"])
        for forbiddenValue in [
            privateUsername, privateSerial, privateDeviceUID, privatePath,
            privateAudio, privateTranscript, privateAPIKey, privateToken,
            privateRawError
        ] {
            XCTAssertFalse(encoded.contains(forbiddenValue))
        }
    }

    func testBoundsEnvironmentStringsWithoutControlCharacters() {
        let metadata = AudioDiagnosticUploadMetadata(
            appVersion: "  1.0\tdebug  ",
            hardwareModel: " M5\rPro ",
            macOSVersion: " 26.5 ",
            inputDevice: .init(name: "Microphone", status: .fallback),
            outputDevice: .init(name: nil, status: .unavailable),
            apiErrorCategory: nil
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: diagnosticReport(),
            metadata: metadata
        )

        XCTAssertEqual(envelope.appVersion, "1.0 debug")
        XCTAssertEqual(envelope.hardwareModel, "M5 Pro")
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
            historicalPlaybackFailed: false,
            microphoneTestOutcome: .succeeded,
            systemAudioTestOutcome: .skipped
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

    func testTimeoutReportExposesStageOutcomeWithoutRawErrorText() throws {
        let facts = AudioDiagnosticFacts(
            microphonePermission: .authorized,
            screenPermission: .authorized,
            inputDeviceAvailable: true,
            outputToneWasScheduled: true,
            userHeardOutputTone: true,
            microphoneMetrics: nil,
            systemAudioMetrics: nil,
            historicalPlaybackFailed: false,
            microphoneTestOutcome: .timedOut,
            systemAudioTestOutcome: .notRun
        )
        let report = AudioDiagnosticReport(
            primaryIssue: .microphoneDiagnosticTimedOut,
            supportingIssues: [],
            facts: facts
        )

        let envelope = AudioDiagnosticSanitizer().makeEnvelope(
            report: report,
            metadata: AudioDiagnosticUploadMetadata(
                appVersion: "1.2.0",
                hardwareModel: "Mac",
                macOSVersion: "26",
                inputDevice: .init(name: "USB Microphone", status: .selected),
                outputDevice: .init(name: "Speaker", status: .automatic),
                apiErrorCategory: nil
            )
        )

        XCTAssertEqual(envelope.schemaVersion, 2)
        XCTAssertEqual(envelope.microphoneTestOutcome, .timedOut)
        XCTAssertEqual(envelope.systemAudioTestOutcome, .notRun)
        XCTAssertEqual(envelope.diagnosticFailureStage, .microphone)
        XCTAssertEqual(envelope.primaryIssueCode, .microphoneDiagnosticTimedOut)
        let encoded = String(
            decoding: try JSONEncoder().encode(envelope),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("timedOut("))
        XCTAssertFalse(encoded.contains("AudioDiagnosticCoordinatorError"))
        XCTAssertTrue(encoded.contains("\"diagnosticFailureStage\":\"microphone\""))
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
        historicalPlaybackFailed: false,
        microphoneTestOutcome: .succeeded,
        systemAudioTestOutcome: .succeeded
    )
    return AudioDiagnosticReport(
        primaryIssue: .captureHealthy,
        supportingIssues: [],
        facts: facts
    )
}
