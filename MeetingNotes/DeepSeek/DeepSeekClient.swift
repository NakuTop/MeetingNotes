import Foundation

struct DeepSeekClient: Sendable {
    private let apiKey: String
    private let httpClient: any HTTPClient
    private let baseURL: URL
    private let chunker: SummaryInputChunker
    private let detailedMinutesLimits: DetailedMinutesInputLimits
    private let detailedMinutesChunker: DetailedMinutesInputChunker
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        apiKey: String,
        httpClient: any HTTPClient,
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
        chunker: SummaryInputChunker = SummaryInputChunker(),
        detailedMinutesLimits: DetailedMinutesInputLimits = .init()
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.chunker = chunker
        self.detailedMinutesLimits = detailedMinutesLimits
        self.detailedMinutesChunker = DetailedMinutesInputChunker(
            byteLimit: detailedMinutesLimits.requestByteLimit
        )
    }

    func testConnection() async throws -> [String] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("models"),
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        authorize(&request)

        let data = try await perform(request)
        do {
            return try decoder.decode(ModelListResponse.self, from: data)
                .data
                .map(\.id)
        } catch {
            throw DeepSeekClientError.invalidResponse
        }
    }

    func summarize(
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        let chunks = chunker.chunks(input.transcripts)
        guard chunks.count > 1 else {
            return try await requestSummary(
                userMessage: try MeetingSummaryPrompt.userMessage(for: input),
                model: model
            )
        }

        var partialSummaries: [GeneratedMeetingSummary] = []
        for chunk in chunks {
            let partialInput = MeetingSummaryInput(
                title: input.title,
                transcripts: chunk,
                bookmarks: []
            )
            partialSummaries.append(
                try await requestSummary(
                    userMessage: try MeetingSummaryPrompt.userMessage(
                        for: partialInput
                    ),
                    model: model
                )
            )
        }

        return try await requestSummary(
            userMessage: MeetingSummaryPrompt.aggregationMessage(
                partialSummaries: partialSummaries,
                title: input.title,
                bookmarks: input.bookmarks
            ),
            model: model
        )
    }

    func detailedMinutes(
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedDetailedMinutes {
        switch try detailedMinutesChunker.plan(for: input) {
        case .direct(let userMessage):
            return try await requestDetailedMinutes(
                userMessage: userMessage,
                model: model
            )
        case .partials(let userMessages):
            var partialMinutes: [GeneratedDetailedMinutes] = []
            for userMessage in userMessages {
                partialMinutes.append(
                    try await requestDetailedMinutes(
                        userMessage: userMessage,
                        model: model
                    )
                )
            }

            let aggregateMessage = try DetailedMinutesPrompt.aggregationMessage(
                partialMinutes: partialMinutes,
                bookmarks: input.bookmarks
            )
            let aggregateByteCount = aggregateMessage.utf8.count
            guard aggregateByteCount <= detailedMinutesLimits.aggregateByteLimit else {
                throw DeepSeekClientError.inputTooLarge
            }
            return try await requestDetailedMinutes(
                userMessage: aggregateMessage,
                model: model
            )
        }
    }

    private func requestSummary(
        userMessage: String,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        do {
            return try await requestJSON(
                systemMessage: MeetingSummaryPrompt.systemMessage,
                userMessage: userMessage,
                responseType: GeneratedMeetingSummary.self,
                model: model,
                maxTokens: 4_096
            )
        } catch ResponseDecodingError.invalidJSON {
            throw DeepSeekClientError.invalidSummaryJSON
        }
    }

    private func requestDetailedMinutes(
        userMessage: String,
        model: String
    ) async throws -> GeneratedDetailedMinutes {
        do {
            return try await requestJSON(
                systemMessage: DetailedMinutesPrompt.systemMessage,
                userMessage: userMessage,
                responseType: GeneratedDetailedMinutes.self,
                model: model,
                maxTokens: 8_192
            )
        } catch ResponseDecodingError.invalidJSON {
            throw DeepSeekClientError.invalidDetailedMinutesJSON
        }
    }

    private func requestJSON<Response: Decodable>(
        systemMessage: String,
        userMessage: String,
        responseType: Response.Type,
        model: String,
        maxTokens: Int
    ) async throws -> Response {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("chat/completions"),
            timeoutInterval: 60
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try encoder.encode(
            ChatCompletionRequest(
                model: model,
                messages: [
                    .init(role: "system", content: systemMessage),
                    .init(role: "user", content: userMessage)
                ],
                maxTokens: maxTokens
            )
        )

        let data = try await perform(request)
        let response: ChatCompletionResponse
        do {
            response = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw DeepSeekClientError.invalidResponse
        }

        guard let choice = response.choices.first else {
            throw DeepSeekClientError.invalidResponse
        }
        switch choice.finishReason {
        case "stop":
            break
        case "length":
            throw DeepSeekClientError.truncated
        case "content_filter":
            throw DeepSeekClientError.contentFiltered
        case "insufficient_system_resource":
            throw DeepSeekClientError.serviceUnavailable
        default:
            throw DeepSeekClientError.unexpectedFinishReason(choice.finishReason)
        }
        guard let content = choice.message.content,
              let contentData = content.data(using: .utf8) else {
            throw DeepSeekClientError.invalidResponse
        }

        do {
            return try decoder.decode(responseType, from: contentData)
        } catch {
            throw ResponseDecodingError.invalidJSON
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            return try await httpClient.data(for: request).0
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as DeepSeekClientError {
            throw error
        } catch HTTPClientError.unacceptableStatus(let status) {
            switch status {
            case 401, 403:
                throw DeepSeekClientError.unauthorized
            case 429:
                throw DeepSeekClientError.rateLimited
            case 500...599:
                throw DeepSeekClientError.server(status)
            default:
                throw DeepSeekClientError.http(status)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw DeepSeekClientError.timeout
        } catch {
            throw DeepSeekClientError.transport
        }
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
}

private struct ModelListResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let responseFormat = ResponseFormat(type: "json_object")
    let thinking = Thinking(type: "disabled")
    let stream = false
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case thinking
        case stream
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    struct Thinking: Encodable {
        let type: String
    }
}

private enum ResponseDecodingError: Error {
    case invalidJSON
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let finishReason: String
        let message: Message

        enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case message
        }
    }

    struct Message: Decodable {
        let content: String?
    }
}
