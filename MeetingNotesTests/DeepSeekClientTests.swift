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
            XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
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

    func testCancellationErrorIsPreservedInsteadOfMappedToTransport() async throws {
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: CancellationThrowingHTTPClient()
        )

        do {
            _ = try await client.summarize(
                input: .init(
                    title: "取消",
                    transcripts: [.init(startTime: 0, endTime: 1, text: "内容")],
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledURLErrorIsPreservedWithOriginalCode() async throws {
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: URLCancellationThrowingHTTPClient()
        )

        do {
            _ = try await client.detailedMinutes(
                input: .init(
                    title: "取消",
                    transcripts: [.init(startTime: 0, endTime: 1, text: "内容")],
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected cancelled URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Expected URLError.cancelled, got \(type(of: error))")
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
            bookmarks: [.init(timestamp: 2, excerpt: "全局书签")],
            userNotes: [
                .init(timestamp: 0.5, text: "分块笔记一"),
                .init(timestamp: 1.5, text: "分块笔记二"),
            ]
        )

        _ = try await client.summarize(input: input, model: "deepseek-v4-flash")

        let bodies = await httpClient.requestBodies()
        XCTAssertEqual(bodies.count, 4)
        let partialNoteTexts = try bodies.dropLast().map { body in
            let payload = try Self.promptPayload(
                from: Self.userMessage(from: body)
            )
            let notes = try XCTUnwrap(
                payload["userNotes"] as? [[String: Any]]
            )
            return notes.compactMap { $0["text"] as? String }
        }
        XCTAssertEqual(
            partialNoteTexts,
            [["分块笔记一"], ["分块笔记二"], []]
        )
        let finalBody = try XCTUnwrap(bodies.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: finalBody) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(object["max_tokens"] as? Int, 4_096)
        let finalUserMessage = try XCTUnwrap(messages.last?["content"])
        let finalPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(finalUserMessage.data(using: .utf8))
            ) as? [String: Any]
        )
        let partials = try XCTUnwrap(
            finalPayload["partialSummaries"] as? [[String: Any]]
        )
        XCTAssertEqual(partials.count, 3)
        XCTAssertEqual(finalPayload["title"] as? String, "长会议")
        let bookmarks = try XCTUnwrap(
            finalPayload["bookmarks"] as? [[String: Any]]
        )
        XCTAssertEqual(bookmarks.first?["excerpt"] as? String, "全局书签")
        let notes = try XCTUnwrap(
            finalPayload["userNotes"] as? [[String: Any]]
        )
        XCTAssertEqual(
            notes.compactMap { $0["text"] as? String },
            ["分块笔记一", "分块笔记二"]
        )
        for body in bodies {
            let encoded = String(decoding: body, as: UTF8.self)
            for forbidden in [
                "screenshots", "relativePath", "fileName", "pixelWidth",
                "pixelHeight", "attachmentID", "imageData",
                "secret-shot.png",
            ] {
                XCTAssertFalse(encoded.contains(forbidden), forbidden)
            }
        }
    }

    func testDetailedMinutesUsesExplicitTokenBudgetAndParsesStructuredDocument() async throws {
        let generated = Self.detailedMinutes(overview: "提炼后的会议概览")
        let httpClient = HTTPClientStub { request in
            let bodyData = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertEqual(messages[0]["content"], DetailedMinutesPrompt.systemMessage)
            let payload = try Self.promptPayload(from: messages)
            XCTAssertEqual(payload["mode"] as? String, "final")
            let transcripts = try XCTUnwrap(
                payload["transcripts"] as? [[String: Any]]
            )
            XCTAssertEqual(transcripts.first?["speakerLabel"] as? String, "我")
            let (response, data) = try Self.chatResponse(
                request: request,
                finishReason: "stop",
                content: String(
                    decoding: try JSONEncoder().encode(generated),
                    as: UTF8.self
                )
            )
            return (data, response)
        }
        let client = DeepSeekClient(apiKey: "test-key", httpClient: httpClient)
        let input = MeetingSummaryInput(
            title: "项目会",
            transcripts: [
                .init(
                    startTime: 0,
                    endTime: 3,
                    text: "先验证方案",
                    speakerLabel: "我"
                )
            ],
            bookmarks: []
        )

        let result = try await client.detailedMinutes(
            input: input,
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(result, generated)
    }

    func testLongDetailedMinutesDecodesEveryPartialThenMakesExactlyOneAggregateRequest() async throws {
        let transcripts = [
            MeetingTranscriptInput(
                startTime: 0,
                endTime: 1,
                text: "raw-11111",
                speakerLabel: "我"
            ),
            MeetingTranscriptInput(
                startTime: 1,
                endTime: 2,
                text: "raw-22222",
                speakerLabel: "远端 1"
            ),
            MeetingTranscriptInput(
                startTime: 2,
                endTime: 3,
                text: "raw-33333",
                speakerLabel: "远端 2"
            )
        ]
        let userNotes = [
            MeetingUserNoteInput(timestamp: 0.5, text: "纪要笔记一"),
            MeetingUserNoteInput(timestamp: 1.5, text: "纪要笔记二"),
            MeetingUserNoteInput(timestamp: 2.5, text: "纪要笔记三"),
        ]
        let requestByteLimit = try Self.limitThatFitsEachPartial(
            title: "长会议",
            transcripts: transcripts,
            userNotes: userNotes
        )
        let responses = [
            Self.detailedMinutes(overview: "已解码局部一"),
            Self.detailedMinutes(overview: "已解码局部二"),
            Self.detailedMinutes(overview: "已解码局部三"),
            Self.detailedMinutes(overview: "最终纪要")
        ]
        let httpClient = SequencedDetailedMinutesHTTPClient(responses: responses)
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: requestByteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )
        let input = MeetingSummaryInput(
            title: "长会议",
            transcripts: transcripts,
            bookmarks: [.init(timestamp: 2, excerpt: "全局书签")],
            userNotes: userNotes
        )

        let result = try await client.detailedMinutes(
            input: input,
            model: "deepseek-v4-flash"
        )

        XCTAssertEqual(result.overview, "最终纪要")
        let bodies = await httpClient.requestBodies()
        XCTAssertEqual(bodies.count, 4)
        for (index, bodyData) in bodies.prefix(3).enumerated() {
            let partialObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            XCTAssertEqual(partialObject["max_tokens"] as? Int, 8_192)
            let partialMessages = try XCTUnwrap(
                partialObject["messages"] as? [[String: String]]
            )
            let partialPayload = try Self.promptPayload(from: partialMessages)
            XCTAssertEqual(partialPayload["mode"] as? String, "partial")
            XCTAssertFalse(
                partialMessages.last?["content"]?.contains("全局书签") == true
            )
            let notes = try XCTUnwrap(
                partialPayload["userNotes"] as? [[String: Any]]
            )
            XCTAssertEqual(
                notes.compactMap { $0["text"] as? String },
                [userNotes[index].text]
            )
        }
        let finalBody = try XCTUnwrap(bodies.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: finalBody) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(object["max_tokens"] as? Int, 8_192)
        let finalUserMessage = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(finalUserMessage.contains("已解码局部一"))
        XCTAssertTrue(finalUserMessage.contains("已解码局部二"))
        XCTAssertTrue(finalUserMessage.contains("已解码局部三"))
        XCTAssertTrue(finalUserMessage.contains("全局书签"))
        for note in userNotes {
            XCTAssertEqual(
                finalUserMessage.components(separatedBy: note.text).count - 1,
                1
            )
        }
        XCTAssertEqual(
            finalUserMessage.components(separatedBy: "全局书签").count - 1,
            1
        )
        XCTAssertFalse(finalUserMessage.contains("raw-11111"))
        XCTAssertFalse(finalUserMessage.contains("raw-22222"))
        XCTAssertFalse(finalUserMessage.contains("raw-33333"))
    }

    func testTruncatedDetailedPartialFailsBeforeAggregation() async throws {
        let transcripts = [
            MeetingTranscriptInput(startTime: 0, endTime: 1, text: "11111"),
            MeetingTranscriptInput(startTime: 1, endTime: 2, text: "22222")
        ]
        let requestByteLimit = try Self.limitThatFitsEachPartial(
            title: "长会议",
            transcripts: transcripts
        )
        let httpClient = TruncatedDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: requestByteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )
        let input = MeetingSummaryInput(
            title: "长会议",
            transcripts: transcripts,
            bookmarks: []
        )

        do {
            _ = try await client.detailedMinutes(
                input: input,
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected truncated partial to fail")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .truncated)
        }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testInvalidDetailedMinutesJSONMapsToDedicatedErrorAndDoesNotAggregate() async throws {
        let transcripts = [
            MeetingTranscriptInput(startTime: 0, endTime: 1, text: "11111"),
            MeetingTranscriptInput(startTime: 1, endTime: 2, text: "22222")
        ]
        let requestByteLimit = try Self.limitThatFitsEachPartial(
            title: "长会议",
            transcripts: transcripts
        )
        let httpClient = InvalidDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: requestByteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )
        let input = MeetingSummaryInput(
            title: "长会议",
            transcripts: transcripts,
            bookmarks: []
        )

        do {
            _ = try await client.detailedMinutes(
                input: input,
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected invalid detailed JSON")
        } catch {
            XCTAssertEqual(
                error as? DeepSeekClientError,
                .invalidDetailedMinutesJSON
            )
        }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testDetailedChunkingCountsTimeLabelsAndJSONEscapingInEncodedByteLimit() async throws {
        let transcripts = [
            MeetingTranscriptInput(
                startTime: 1_234.567,
                endTime: 1_235.678,
                text: "短文本",
                speakerLabel: "我"
            ),
            MeetingTranscriptInput(
                startTime: 9_876.543,
                endTime: 9_999.999,
                text: "引号\"、反斜线\\与换行\n都必须计入",
                speakerLabel: "远端 123"
            )
        ]
        let byteLimit = try Self.limitThatFitsEachPartial(
            title: "编码预算会议",
            transcripts: transcripts
        )
        let httpClient = RecordingDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: byteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )

        _ = try await client.detailedMinutes(
            input: .init(
                title: "编码预算会议",
                transcripts: transcripts,
                bookmarks: []
            ),
            model: "deepseek-v4-flash"
        )

        let bodies = await httpClient.requestBodies()
        XCTAssertEqual(bodies.count, 3)
        for body in bodies.dropLast() {
            let userMessage = try Self.userMessage(from: body)
            XCTAssertLessThanOrEqual(userMessage.utf8.count, byteLimit)
            let payload = try Self.promptPayload(from: userMessage)
            XCTAssertEqual(payload["mode"] as? String, "partial")
        }
    }

    func testOversizedTranscriptSplitsOnCharactersWithoutLossAndAllPayloadsFit() async throws {
        let originalText = String(
            repeating: "中👨‍👩‍👧‍👦e\u{301}\n\"\\",
            count: 8
        )
        let original = MeetingTranscriptInput(
            startTime: 12.5,
            endTime: 88.25,
            text: originalText,
            speakerLabel: "远端 9"
        )
        let singleCharacterLimits = try originalText.map { character in
            try DetailedMinutesPrompt.partialUserMessage(
                for: .init(
                    title: "Unicode 长段",
                    transcripts: [
                        .init(
                            startTime: original.startTime,
                            endTime: original.endTime,
                            text: String(character),
                            speakerLabel: original.speakerLabel
                        )
                    ],
                    bookmarks: []
                )
            ).utf8.count
        }
        let byteLimit = try XCTUnwrap(singleCharacterLimits.max())
        XCTAssertGreaterThan(
            try DetailedMinutesPrompt.partialUserMessage(
                for: .init(
                    title: "Unicode 长段",
                    transcripts: [original],
                    bookmarks: []
                )
            ).utf8.count,
            byteLimit
        )
        let httpClient = RecordingDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: byteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )

        _ = try await client.detailedMinutes(
            input: .init(
                title: "Unicode 长段",
                transcripts: [original],
                bookmarks: []
            ),
            model: "deepseek-v4-flash"
        )

        let bodies = await httpClient.requestBodies()
        let partialBodies = bodies.dropLast()
        XCTAssertGreaterThan(partialBodies.count, 1)
        var reconstructed = ""
        for body in partialBodies {
            let userMessage = try Self.userMessage(from: body)
            XCTAssertLessThanOrEqual(userMessage.utf8.count, byteLimit)
            let payload = try Self.promptPayload(from: userMessage)
            let encodedTranscripts = try XCTUnwrap(
                payload["transcripts"] as? [[String: Any]]
            )
            for transcript in encodedTranscripts {
                XCTAssertEqual(transcript["startTime"] as? Double, original.startTime)
                XCTAssertEqual(transcript["endTime"] as? Double, original.endTime)
                XCTAssertEqual(
                    transcript["speakerLabel"] as? String,
                    original.speakerLabel
                )
                reconstructed += try XCTUnwrap(transcript["text"] as? String)
            }
        }
        XCTAssertEqual(reconstructed, originalText)
        XCTAssertEqual(Array(reconstructed), Array(originalText))
    }

    func testDetailedFixedOverheadBeyondLimitFailsWithoutSendingRequest() async throws {
        let httpClient = RecordingDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: 1,
                aggregateByteLimit: 256 * 1_024
            )
        )

        do {
            _ = try await client.detailedMinutes(
                input: .init(
                    title: "固定开销已经超限",
                    transcripts: [.init(startTime: 0, endTime: 1, text: "内容")],
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected inputTooLarge")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .inputTooLarge)
        }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testOversizedAggregateFailsAfterPartialsWithoutSendingFinalRequest() async throws {
        let transcripts = [
            MeetingTranscriptInput(startTime: 0, endTime: 1, text: "第一段"),
            MeetingTranscriptInput(startTime: 1, endTime: 2, text: "第二段")
        ]
        let byteLimit = try Self.limitThatFitsEachPartial(
            title: "聚合超限",
            transcripts: transcripts
        )
        let httpClient = RecordingDetailedMinutesHTTPClient()
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: byteLimit,
                aggregateByteLimit: 1
            )
        )

        do {
            _ = try await client.detailedMinutes(
                input: .init(
                    title: "聚合超限",
                    transcripts: transcripts,
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected inputTooLarge")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .inputTooLarge)
        }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testTruncatedFinalAggregateFailsWholeDetailedMinutesRequest() async throws {
        let transcripts = [
            MeetingTranscriptInput(startTime: 0, endTime: 1, text: "第一段"),
            MeetingTranscriptInput(startTime: 1, endTime: 2, text: "第二段")
        ]
        let byteLimit = try Self.limitThatFitsEachPartial(
            title: "最终截断",
            transcripts: transcripts
        )
        let httpClient = FinalAggregateTruncatedHTTPClient(partialCount: 2)
        let client = DeepSeekClient(
            apiKey: "test-key",
            httpClient: httpClient,
            detailedMinutesLimits: .init(
                requestByteLimit: byteLimit,
                aggregateByteLimit: 256 * 1_024
            )
        )

        do {
            _ = try await client.detailedMinutes(
                input: .init(
                    title: "最终截断",
                    transcripts: transcripts,
                    bookmarks: []
                ),
                model: "deepseek-v4-flash"
            )
            XCTFail("Expected truncated aggregate")
        } catch {
            XCTAssertEqual(error as? DeepSeekClientError, .truncated)
        }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 3)
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

    private static func limitThatFitsEachPartial(
        title: String,
        transcripts: [MeetingTranscriptInput],
        userNotes: [MeetingUserNoteInput] = []
    ) throws -> Int {
        let partitionedNotes = MeetingUserNoteInputPolicy.partition(
            userNotes,
            across: transcripts.map { [$0] }
        )
        let individualSizes = try transcripts.enumerated().map {
            index, transcript in
            try DetailedMinutesPrompt.partialUserMessage(
                for: .init(
                    title: title,
                    transcripts: [transcript],
                    bookmarks: [],
                    userNotes: partitionedNotes[index]
                )
            ).utf8.count
        }
        let limit = try XCTUnwrap(individualSizes.max())
        let directSize = try DetailedMinutesPrompt.userMessage(
            for: .init(
                title: title,
                transcripts: transcripts,
                bookmarks: [],
                userNotes: userNotes
            )
        ).utf8.count
        XCTAssertGreaterThan(directSize, limit)
        return limit
    }

    private static func userMessage(from body: Data) throws -> String {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        return try XCTUnwrap(messages.last?["content"])
    }

    private static func promptPayload(
        from messages: [[String: String]]
    ) throws -> [String: Any] {
        try promptPayload(from: XCTUnwrap(messages.last?["content"]))
    }

    private static func promptPayload(
        from userMessage: String
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(userMessage.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func detailedMinutes(
        overview: String
    ) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: [
                .init(
                    title: "主题",
                    timeRange: nil,
                    speakers: [],
                    content: "已提炼内容"
                )
            ],
            decisions: [],
            actionItems: [],
            openQuestions: []
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

private actor SequencedDetailedMinutesHTTPClient: HTTPClient {
    private let responses: [GeneratedDetailedMinutes]
    private var bodies: [Data] = []

    init(responses: [GeneratedDetailedMinutes]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(request.httpBody ?? Data())
        let index = bodies.count - 1
        let content = String(
            decoding: try JSONEncoder().encode(responses[index]),
            as: UTF8.self
        )
        return try makeDetailedChatResponse(request: request, content: content)
    }

    func requestBodies() -> [Data] {
        bodies
    }
}

private actor TruncatedDetailedMinutesHTTPClient: HTTPClient {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return try makeDetailedChatResponse(
            request: request,
            finishReason: "length",
            content: "{\"overview\":\"truncated"
        )
    }

    func requestCount() -> Int {
        count
    }
}

private actor InvalidDetailedMinutesHTTPClient: HTTPClient {
    private var count = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return try makeDetailedChatResponse(
            request: request,
            content: "not-json"
        )
    }

    func requestCount() -> Int {
        count
    }
}

private struct CancellationThrowingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CancellationError()
    }
}

private struct URLCancellationThrowingHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cancelled)
    }
}

private actor RecordingDetailedMinutesHTTPClient: HTTPClient {
    private var bodies: [Data] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(request.httpBody ?? Data())
        let generated = GeneratedDetailedMinutes(
            overview: "局部或最终纪要",
            sections: [],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
        return try makeDetailedChatResponse(
            request: request,
            content: String(
                decoding: try JSONEncoder().encode(generated),
                as: UTF8.self
            )
        )
    }

    func requestBodies() -> [Data] {
        bodies
    }

    func requestCount() -> Int {
        bodies.count
    }
}

private actor FinalAggregateTruncatedHTTPClient: HTTPClient {
    private let partialCount: Int
    private var count = 0

    init(partialCount: Int) {
        self.partialCount = partialCount
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        if count > partialCount {
            return try makeDetailedChatResponse(
                request: request,
                finishReason: "length",
                content: "{\"overview\":\"truncated"
            )
        }
        let generated = GeneratedDetailedMinutes(
            overview: "已完成局部 \(count)",
            sections: [],
            decisions: [],
            actionItems: [],
            openQuestions: []
        )
        return try makeDetailedChatResponse(
            request: request,
            content: String(
                decoding: try JSONEncoder().encode(generated),
                as: UTF8.self
            )
        )
    }

    func requestCount() -> Int {
        count
    }
}

private func makeDetailedChatResponse(
    request: URLRequest,
    finishReason: String = "stop",
    content: String
) throws -> (Data, HTTPURLResponse) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
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
    return (data, response)
}
