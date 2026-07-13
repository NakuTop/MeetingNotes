import XCTest
@testable import MeetingNotes

final class DeepSeekClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testConnectionUsesBearerHeaderAndParsesModels() async throws {
        let apiKey = "test-deepseek-key"
        URLProtocolStub.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/models")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(apiKey)"
            )
            return try Self.response(
                request: request,
                status: 200,
                object: [
                    "object": "list",
                    "data": [
                        ["id": "deepseek-v4-flash", "object": "model", "owned_by": "deepseek"],
                        ["id": "deepseek-v4-pro", "object": "model", "owned_by": "deepseek"]
                    ]
                ]
            )
        }
        let client = makeClient(apiKey: apiKey)

        let models = try await client.testConnection()

        XCTAssertEqual(models, ["deepseek-v4-flash", "deepseek-v4-pro"])
    }

    func testSummaryRequestUsesJSONOutputAndParsesStructuredSummary() async throws {
        let transcriptText = "王小明确认下周启动。"
        let httpClient = HTTPClientStub { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.deepseek.com/chat/completions"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let bodyData = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "deepseek-v4-flash")
            XCTAssertEqual(body["stream"] as? Bool, false)
            let responseFormat = try XCTUnwrap(body["response_format"] as? [String: String])
            XCTAssertEqual(responseFormat["type"], "json_object")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertTrue(messages[0]["content"]?.contains("只输出 JSON") == true)
            XCTAssertTrue(messages[1]["content"]?.contains(transcriptText) == true)

            let summaryJSON = try JSONSerialization.data(
                withJSONObject: [
                    "suggestedTitle": "项目启动会",
                    "overview": "确认了启动计划。",
                    "keyPoints": ["下周启动"],
                    "decisions": ["按计划执行"],
                    "actionItems": [
                        ["task": "准备排期", "owner": NSNull(), "dueDate": NSNull()]
                    ],
                    "bookmarkInsights": ["00:05 启动决定"]
                ]
            )
            let content = try XCTUnwrap(String(data: summaryJSON, encoding: .utf8))
            let (response, data) = try Self.chatResponse(
                request: request,
                finishReason: "stop",
                content: content
            )
            return (data, response)
        }
        let client = DeepSeekClient(apiKey: "test-key", httpClient: httpClient)
        let input = MeetingSummaryInput(
            title: "例会",
            transcripts: [
                .init(startTime: 0, endTime: 5, text: transcriptText)
            ],
            bookmarks: [
                .init(timestamp: 5, excerpt: "启动决定")
            ]
        )

        let summary = try await client.summarize(
            input: input,
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(summary.suggestedTitle, "项目启动会")
        XCTAssertEqual(summary.overview, "确认了启动计划。")
        XCTAssertEqual(summary.keyPoints, ["下周启动"])
        XCTAssertEqual(summary.decisions, ["按计划执行"])
        XCTAssertEqual(
            summary.actionItems,
            [.init(task: "准备排期", owner: nil, dueDate: nil)]
        )
        XCTAssertEqual(summary.bookmarkInsights, ["00:05 启动决定"])
    }

    func testMapsFinishReasonAndInvalidJSONToDistinctErrors() async throws {
        try await assertSummaryError(
            finishReason: "length",
            content: "{}",
            expected: .truncated
        )
        try await assertSummaryError(
            finishReason: "stop",
            content: "not-json",
            expected: .invalidSummaryJSON
        )
    }

    func testMapsHTTPStatusesAndTimeoutWithoutExposingSensitiveInput() async throws {
        try await assertStatusError(401, expected: .unauthorized)
        try await assertStatusError(429, expected: .rateLimited)
        try await assertStatusError(503, expected: .server(503))

        URLProtocolStub.setHandler { _ in
            throw URLError(.timedOut)
        }
        let key = "must-not-appear-api-key"
        let transcript = "must-not-appear-full-transcript"
        let client = makeClient(apiKey: key)
        do {
            _ = try await client.summarize(
                input: .init(
                    title: "测试",
                    transcripts: [.init(startTime: 0, endTime: 1, text: transcript)],
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .timeout)
            let description = String(describing: error)
            XCTAssertFalse(description.contains(key))
            XCTAssertFalse(description.contains(transcript))
        }
    }

    func testLongInputUsesPartialSummariesThenOneFinalAggregation() async throws {
        let httpClient = RepeatingSummaryHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            chunker: SummaryInputChunker(characterBudget: 5)
        )
        let input = MeetingSummaryInput(
            title: "长会议",
            transcripts: [
                .init(startTime: 0, endTime: 1, text: "11111"),
                .init(startTime: 1, endTime: 2, text: "22222"),
                .init(startTime: 2, endTime: 3, text: "33333")
            ],
            bookmarks: [.init(timestamp: 2, excerpt: "全局书签")]
        )

        _ = try await client.summarize(input: input, model: "deepseek-v4-flash")

        let bodies = await httpClient.requestBodies()
        XCTAssertEqual(bodies.count, 4)
        let finalBody = try XCTUnwrap(bodies.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: finalBody) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let finalUserMessage = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(finalUserMessage.contains("局部摘要"))
        XCTAssertTrue(finalUserMessage.contains("全局书签"))
    }

    private func assertStatusError(
        _ status: Int,
        expected: DeepSeekClientError
    ) async throws {
        let secret = "response-secret-\(status)"
        URLProtocolStub.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(secret.utf8))
        }
        let client = makeClient(apiKey: "secret-key-\(status)")
        do {
            _ = try await client.testConnection()
            XCTFail("Expected status error")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, expected)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    private func assertSummaryError(
        finishReason: String,
        content: String,
        expected: DeepSeekClientError
    ) async throws {
        URLProtocolStub.setHandler { request in
            try Self.chatResponse(
                request: request,
                finishReason: finishReason,
                content: content
            )
        }
        let client = makeClient(apiKey: "test-key")
        do {
            _ = try await client.summarize(
                input: .init(
                    title: "测试",
                    transcripts: [.init(startTime: 0, endTime: 1, text: "转录")],
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected summary error")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, expected)
        }
    }

    private func makeClient(apiKey: String) -> DeepSeekClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.urlCache = nil
        let httpClient = URLSessionHTTPClient(
            session: URLSession(configuration: configuration)
        )
        return DeepSeekClient(apiKey: apiKey, httpClient: httpClient)
    }

    private static func response(
        request: URLRequest,
        status: Int,
        object: Any
    ) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, try JSONSerialization.data(withJSONObject: object))
    }

    private static func chatResponse(
        request: URLRequest,
        finishReason: String,
        content: String
    ) throws -> (HTTPURLResponse, Data) {
        try response(
            request: request,
            status: 200,
            object: [
                "choices": [
                    [
                        "finish_reason": finishReason,
                        "message": ["content": content, "role": "assistant"]
                    ]
                ]
            ]
        )
    }
}

private actor RepeatingSummaryHTTPClient: HTTPClient {
    private var bodies: [Data] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(request.httpBody ?? Data())
        let summary = GeneratedMeetingSummary(
            suggestedTitle: "局部摘要",
            overview: "摘要",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: []
        )
        let contentData = try JSONEncoder().encode(summary)
        let content = String(decoding: contentData, as: UTF8.self)
        let responseData = try JSONSerialization.data(
            withJSONObject: [
                "choices": [
                    [
                        "finish_reason": "stop",
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
        return (responseData, response)
    }

    func requestBodies() -> [Data] {
        bodies
    }
}
