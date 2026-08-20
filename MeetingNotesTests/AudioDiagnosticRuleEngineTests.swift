import XCTest
@testable import MeetingNotes

final class AudioDiagnosticRuleEngineTests: XCTestCase {
    func testRuleTableUsesStablePrecedenceAndSupportingOrder() throws {
        let cases: [RuleCase] = [
            RuleCase(
                name: "microphone permission outranks all later failures",
                facts: facts(
                    microphonePermission: .denied,
                    inputDeviceAvailable: false,
                    outputToneWasScheduled: true,
                    userHeardOutputTone: false,
                    microphoneMetrics: noFrames(),
                    systemAudioMetrics: noFrames()
                ),
                primary: .microphonePermissionDenied,
                supporting: [
                    .inputDeviceUnavailable,
                    .outputNotAudible,
                    .microphoneNoFrames,
                    .systemAudioNoFrames
                ]
            ),
            RuleCase(
                name: "screen permission outranks system signal failure",
                facts: facts(
                    screenPermission: .denied,
                    systemAudioMetrics: noFrames()
                ),
                primary: .screenPermissionDenied,
                supporting: [.systemAudioNoFrames]
            ),
            RuleCase(
                name: "selected input unavailable outranks signal failure",
                facts: facts(
                    inputDeviceAvailable: false,
                    microphoneMetrics: noFrames()
                ),
                primary: .inputDeviceUnavailable,
                supporting: [.microphoneNoFrames]
            ),
            RuleCase(
                name: "scheduled unheard tone outranks signal failure",
                facts: facts(
                    outputToneWasScheduled: true,
                    userHeardOutputTone: false,
                    microphoneMetrics: noFrames()
                ),
                primary: .outputNotAudible,
                supporting: [.microphoneNoFrames]
            ),
            RuleCase(
                name: "microphone no frames with healthy system track",
                facts: facts(
                    microphoneMetrics: noFrames(),
                    systemAudioMetrics: audible()
                ),
                primary: .microphoneNoFrames
            ),
            RuleCase(
                name: "system no frames with healthy microphone track",
                facts: facts(
                    microphoneMetrics: audible(),
                    systemAudioMetrics: noFrames()
                ),
                primary: .systemAudioNoFrames
            ),
            RuleCase(
                name: "both tracks healthy",
                facts: facts(
                    microphoneMetrics: audible(),
                    systemAudioMetrics: audible()
                ),
                primary: .captureHealthy
            ),
            RuleCase(
                name: "healthy capture with historical playback failure",
                facts: facts(
                    microphoneMetrics: audible(),
                    systemAudioMetrics: audible(),
                    historicalPlaybackFailed: true
                ),
                primary: .playbackPipelineSuspected
            )
        ]

        let engine = AudioDiagnosticRuleEngine()
        for testCase in cases {
            let report = try XCTUnwrap(engine.evaluate(testCase.facts))

            XCTAssertEqual(
                report.primaryIssue,
                testCase.primary,
                testCase.name
            )
            XCTAssertEqual(
                report.supportingIssues,
                testCase.supporting,
                testCase.name
            )
        }
    }

    func testSilentMicrophoneRequiresAtLeastTwoSecondsOfObservation()
        throws {
        let engine = AudioDiagnosticRuleEngine()

        let shortReport = engine.evaluate(
            facts(microphoneMetrics: silent(duration: 1.999))
        )
        let longReport = try XCTUnwrap(
            engine.evaluate(
                facts(microphoneMetrics: silent(duration: 2))
            )
        )

        XCTAssertNil(shortReport)
        XCTAssertEqual(longReport.primaryIssue, .microphoneSilent)
    }

    func testVeryLowMicrophoneUsesTheSameContinuousWindowGuard() throws {
        let engine = AudioDiagnosticRuleEngine()

        let shortReport = engine.evaluate(
            facts(microphoneMetrics: veryLow(duration: 1))
        )
        let longReport = try XCTUnwrap(
            engine.evaluate(
                facts(microphoneMetrics: veryLow(duration: 3))
            )
        )

        XCTAssertNil(shortReport)
        XCTAssertEqual(longReport.primaryIssue, .microphoneSilent)
    }

    func testPlaybackSuspicionIsNotReportedWhenCaptureHasFailed() throws {
        let report = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    microphoneMetrics: noFrames(),
                    historicalPlaybackFailed: true
                )
            )
        )

        XCTAssertEqual(report.primaryIssue, .microphoneNoFrames)
        XCTAssertFalse(
            report.supportingIssues.contains(.playbackPipelineSuspected)
        )
    }

    func testPlaybackSuspicionIsOnlyReportedAsPrimaryAfterFullyHealthyCapture()
        throws {
        let report = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    microphonePermission: .denied,
                    microphoneMetrics: audible(),
                    historicalPlaybackFailed: true
                )
            )
        )

        XCTAssertEqual(report.primaryIssue, .microphonePermissionDenied)
        XCTAssertFalse(
            report.supportingIssues.contains(.playbackPipelineSuspected)
        )
    }

    func testNoMicrophoneEvidenceDoesNotClaimCaptureHealthy() {
        XCTAssertNil(
            AudioDiagnosticRuleEngine().evaluate(facts())
        )
    }

    func testAuthorizedScreenCaptureRequiresSystemAudioEvidence() {
        XCTAssertNil(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    screenPermission: .authorized,
                    microphoneMetrics: audible()
                )
            )
        )
    }

    func testScheduledToneRequiresUserConfirmationBeforeHealthyReport() {
        XCTAssertNil(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    outputToneWasScheduled: true,
                    microphoneMetrics: audible()
                )
            )
        )
    }

    func testKnownIssueReturnsReportWhenCaptureMetricsAreMissing() throws {
        let cases: [(AudioDiagnosticFacts, AudioDiagnosticIssueCode)] = [
            (
                facts(microphonePermission: .denied),
                .microphonePermissionDenied
            ),
            (
                facts(inputDeviceAvailable: false),
                .inputDeviceUnavailable
            ),
            (
                facts(
                    outputToneWasScheduled: true,
                    userHeardOutputTone: false
                ),
                .outputNotAudible
            )
        ]

        for testCase in cases {
            let report = try XCTUnwrap(
                AudioDiagnosticRuleEngine().evaluate(testCase.0)
            )
            XCTAssertEqual(report.primaryIssue, testCase.1)
        }
    }

    func testSystemLowLevelRequiresTwoSecondsBeforeReportingFailure()
        throws {
        let shortSilent = AudioDiagnosticRuleEngine().evaluate(
            facts(
                screenPermission: .authorized,
                microphoneMetrics: audible(),
                systemAudioMetrics: silent(duration: 1.999)
            )
        )
        let shortVeryLow = AudioDiagnosticRuleEngine().evaluate(
            facts(
                screenPermission: .authorized,
                microphoneMetrics: audible(),
                systemAudioMetrics: veryLow(duration: 1)
            )
        )
        let longSilent = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    screenPermission: .authorized,
                    microphoneMetrics: audible(),
                    systemAudioMetrics: silent(duration: 2)
                )
            )
        )
        let longVeryLow = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    screenPermission: .authorized,
                    microphoneMetrics: audible(),
                    systemAudioMetrics: veryLow(duration: 3)
                )
            )
        )

        XCTAssertNil(shortSilent)
        XCTAssertNil(shortVeryLow)
        XCTAssertEqual(longSilent.primaryIssue, .systemAudioNoFrames)
        XCTAssertEqual(longVeryLow.primaryIssue, .systemAudioNoFrames)
    }

    func testCaptureHealthyRequiresEveryApplicableTrackToBeAudible()
        throws {
        let offlineReport = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(microphoneMetrics: audible())
            )
        )
        let onlineReport = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(
                facts(
                    screenPermission: .authorized,
                    microphoneMetrics: audible(),
                    systemAudioMetrics: audible()
                )
            )
        )

        XCTAssertEqual(offlineReport.primaryIssue, .captureHealthy)
        XCTAssertEqual(onlineReport.primaryIssue, .captureHealthy)
    }

    func testReportRetainsTheExactDiagnosticFacts() throws {
        let input = facts(
            microphoneMetrics: noFrames(),
            historicalPlaybackFailed: true
        )

        let report = try XCTUnwrap(
            AudioDiagnosticRuleEngine().evaluate(input)
        )

        XCTAssertEqual(report.facts, input)
    }

    func testSystemAudioFallbackDescribesMissingValidAudio() {
        XCTAssertEqual(
            AudioDiagnosticIssueCode.systemAudioNoFrames.localIssue,
            "未检测到有效的系统声音"
        )
        XCTAssertTrue(
            AudioDiagnosticIssueCode.systemAudioNoFrames.localSolution
                .contains("系统声音")
        )
    }

    func testIssueCodesExposeStableChineseFallbacks() {
        for code in AudioDiagnosticIssueCode.allCases {
            XCTAssertFalse(code.localIssue.isEmpty, code.rawValue)
            XCTAssertFalse(code.localSolution.isEmpty, code.rawValue)
        }
    }

    func testIssueCodesAndLevelBandsRoundTripThroughCodableRawValues()
        throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for code in AudioDiagnosticIssueCode.allCases {
            XCTAssertEqual(
                try decoder.decode(
                    AudioDiagnosticIssueCode.self,
                    from: encoder.encode(code)
                ),
                code
            )
        }
        for level in AudioLevelBand.allCases {
            XCTAssertEqual(
                try decoder.decode(
                    AudioLevelBand.self,
                    from: encoder.encode(level)
                ),
                level
            )
        }
    }
}

private struct RuleCase {
    let name: String
    let facts: AudioDiagnosticFacts
    let primary: AudioDiagnosticIssueCode
    let supporting: [AudioDiagnosticIssueCode]

    init(
        name: String,
        facts: AudioDiagnosticFacts,
        primary: AudioDiagnosticIssueCode,
        supporting: [AudioDiagnosticIssueCode] = []
    ) {
        self.name = name
        self.facts = facts
        self.primary = primary
        self.supporting = supporting
    }
}

private func facts(
    microphonePermission: AudioDiagnosticPermissionStatus = .authorized,
    screenPermission: AudioDiagnosticPermissionStatus? = nil,
    inputDeviceAvailable: Bool = true,
    outputToneWasScheduled: Bool = false,
    userHeardOutputTone: Bool? = nil,
    microphoneMetrics: AudioSignalMetrics? = nil,
    systemAudioMetrics: AudioSignalMetrics? = nil,
    historicalPlaybackFailed: Bool = false,
    microphoneTestOutcome: AudioDiagnosticStageOutcome = .notRun,
    systemAudioTestOutcome: AudioDiagnosticStageOutcome = .notRun
) -> AudioDiagnosticFacts {
    AudioDiagnosticFacts(
        microphonePermission: microphonePermission,
        screenPermission: screenPermission,
        inputDeviceAvailable: inputDeviceAvailable,
        outputToneWasScheduled: outputToneWasScheduled,
        userHeardOutputTone: userHeardOutputTone,
        microphoneMetrics: microphoneMetrics,
        systemAudioMetrics: systemAudioMetrics,
        historicalPlaybackFailed: historicalPlaybackFailed,
        microphoneTestOutcome: microphoneTestOutcome,
        systemAudioTestOutcome: systemAudioTestOutcome
    )
}

private func noFrames() -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 0,
        rms: 0,
        peak: 0,
        observationDuration: 3,
        sampleRate: 48_000,
        channelCount: 1,
        level: .noFrames
    )
}

private func silent(duration: TimeInterval) -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 48_000,
        rms: 0,
        peak: 0,
        observationDuration: duration,
        sampleRate: 48_000,
        channelCount: 1,
        level: .silent
    )
}

private func veryLow(duration: TimeInterval) -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 48_000,
        rms: 0.001,
        peak: 0.001,
        observationDuration: duration,
        sampleRate: 48_000,
        channelCount: 1,
        level: .veryLow
    )
}

private func audible() -> AudioSignalMetrics {
    AudioSignalMetrics(
        sampleCount: 48_000,
        rms: 0.1,
        peak: 0.25,
        observationDuration: 3,
        sampleRate: 48_000,
        channelCount: 1,
        level: .audible
    )
}
