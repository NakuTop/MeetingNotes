import XCTest
@testable import MeetingNotes

final class DeepSeekAudioDiagnosticClientTests: XCTestCase {
    func testRequestUsesStrictPrivacyEnvelopeAndParsesTrimmedExplanation()
        async throws {
        let apiKey = "api-key-must-stay-in-header"
        let httpClient = HTTPClientStub { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.deepseek.com/chat/completions"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(apiKey)"
            )
            let bodyData = try XCTUnwrap(request.httpBody)
            let bodyText = String(decoding: bodyData, as: UTF8.self)
            XCTAssertFalse(bodyText.contains(apiKey))
            XCTAssertFalse(bodyText.contains("rawAudio"))
            XCTAssertFalse(bodyText.contains("transcript"))
            XCTAssertFalse(bodyText.contains("meetingContent"))

            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData)
                    as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "deepseek-chat")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["max_tokens"] as? Int, 256)
            XCTAssertEqual(
                (body["response_format"] as? [String: String])?["type"],
                "json_object"
            )
            let messages = try XCTUnwrap(
                body["messages"] as? [[String: String]]
            )
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertEqual(
                messages[0]["content"],
                DeepSeekAudioDiagnosticClient.systemPrompt
            )
            let envelopeData = Data(
                try XCTUnwrap(messages[1]["content"]).utf8
            )
            let envelope = try JSONDecoder().decode(
                AudioDiagnosticUploadEnvelope.self,
                from: envelopeData
            )
            XCTAssertEqual(envelope.primaryIssueCode, .captureHealthy)
            XCTAssertEqual(envelope.inputDevice.status, .selected)
            XCTAssertFalse(envelopeData.contains(Data("USB Microphone".utf8)))
            XCTAssertFalse(envelopeData.contains(Data("Display Audio".utf8)))

            return try chatResponse(
                request: request,
                finishReason: "stop",
                content: """
                {"issue":"  音频采集正常  ","solution":"  无需修改设备。  "}
                """
            )
        }
        let client = DeepSeekAudioDiagnosticClient(
            apiKey: apiKey,
            httpClient: httpClient
        )

        let result = try await client.requestExplanation(
            report: clientDiagnosticReport(),
            metadata: uploadMetadata(),
            model: "deepseek-chat"
        )

        XCTAssertEqual(result.issue, "音频采集正常")
        XCTAssertEqual(result.solution, "无需修改设备。")
        XCTAssertEqual(result.source, .deepSeek)
    }

    func testRejectsNonStopMissingEmptyOverlongAndControlCharacterResponses()
        async throws {
        try await assertRequestError(
            content: "not-json",
            expected: .invalidDiagnosticJSON
        )
        try await assertRequestError(
            finishReason: "length",
            content: "{\"issue\":\"问题\",\"solution\":\"方案\"}",
            expected: .truncated
        )
        try await assertRequestError(
            content: "{\"issue\":\"问题\"}",
            expected: .invalidDiagnosticJSON
        )
        try await assertRequestError(
            content: "{\"issue\":\"   \",\"solution\":\"方案\"}",
            expected: .invalidDiagnosticExplanation
        )
        try await assertRequestError(
            content: "{\"issue\":\"\(String(repeating: "长", count: 61))\",\"solution\":\"方案\"}",
            expected: .invalidDiagnosticExplanation
        )
        try await assertRequestError(
            content: "{\"issue\":\"问题\\n换行\",\"solution\":\"方案\"}",
            expected: .invalidDiagnosticExplanation
        )
        try await assertRequestError(
            content: "{\"issue\":\"问题\",\"solution\":\"方案\",\"extra\":true}",
            expected: .invalidDiagnosticJSON
        )
    }

    func testPublicExplainFallsBackToDeterministicLocalResult() async {
        let httpClient = HTTPClientStub { _ in
            throw HTTPClientError.unacceptableStatus(401)
        }
        let client = DeepSeekAudioDiagnosticClient(
            apiKey: "secret-key",
            httpClient: httpClient
        )

        let result = await client.explain(
            report: clientDiagnosticReport(),
            metadata: uploadMetadata(),
            model: "deepseek-chat"
        )

        XCTAssertEqual(result.issue, clientDiagnosticReport().localIssue)
        XCTAssertEqual(result.solution, clientDiagnosticReport().localSolution)
        XCTAssertEqual(result.source, .localFallback)
    }

    func testMapsTimeoutAndUnauthorizedWithoutSensitiveDescriptions()
        async throws {
        let timeoutClient = DeepSeekAudioDiagnosticClient(
            apiKey: "secret-timeout-key",
            httpClient: HTTPClientStub { _ in throw URLError(.timedOut) }
        )
        do {
            _ = try await timeoutClient.requestExplanation(
                report: clientDiagnosticReport(),
                metadata: uploadMetadata(),
                model: "deepseek-chat"
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .timeout)
            XCTAssertFalse(String(describing: error).contains("secret-timeout-key"))
        }

        let unauthorizedClient = DeepSeekAudioDiagnosticClient(
            apiKey: "secret-unauthorized-key",
            httpClient: HTTPClientStub { _ in
                throw HTTPClientError.unacceptableStatus(403)
            }
        )
        do {
            _ = try await unauthorizedClient.requestExplanation(
                report: clientDiagnosticReport(),
                metadata: uploadMetadata(),
                model: "deepseek-chat"
            )
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .unauthorized)
        }
    }

    private func assertRequestError(
        finishReason: String = "stop",
        content: String,
        expected: DeepSeekClientError
    ) async throws {
        let client = DeepSeekAudioDiagnosticClient(
            apiKey: "test-key",
            httpClient: HTTPClientStub { request in
                try chatResponse(
                    request: request,
                    finishReason: finishReason,
                    content: content
                )
            }
        )
        do {
            _ = try await client.requestExplanation(
                report: clientDiagnosticReport(),
                metadata: uploadMetadata(),
                model: "deepseek-chat"
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, expected)
        }
    }
}

private func uploadMetadata() -> AudioDiagnosticUploadMetadata {
    AudioDiagnosticUploadMetadata(
        appVersion: "1.0",
        hardwareModel: "MacBook Pro M5",
        macOSVersion: "26.5",
        inputDevice: .init(name: "USB Microphone", status: .selected),
        outputDevice: .init(name: "Display Audio", status: .automatic),
        apiErrorCategory: nil
    )
}

private func clientDiagnosticReport() -> AudioDiagnosticReport {
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

private func chatResponse(
    request: URLRequest,
    finishReason: String,
    content: String
) throws -> (Data, HTTPURLResponse) {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "choices": [
                [
                    "finish_reason": finishReason,
                    "message": ["content": content, "role": "assistant"]
                ]
            ]
        ]
    )
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    return (data, response)
}
