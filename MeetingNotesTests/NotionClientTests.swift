import XCTest
@testable import MeetingNotes

final class NotionClientTests: XCTestCase {
    func testConnectionChecksBotThenParentPageWithCurrentHeaders() async throws {
        let parentID = try XCTUnwrap(
            UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef")
        )
        let httpClient = QueuedNotionHTTPClient(responses: [
            .json([
                "object": "user",
                "id": "bot-id",
                "name": "Meeting Bot"
            ]),
            .json([
                "object": "page",
                "id": parentID.uuidString.lowercased(),
                "url": "https://www.notion.so/parent",
                "properties": [
                    "Name": [
                        "type": "title",
                        "title": [["plain_text": "团队会议库"]]
                    ]
                ]
            ])
        ])
        let client = NotionClient(token: "test-token", httpClient: httpClient)

        let result = try await client.testConnection(parentPageID: parentID)

        XCTAssertEqual(result.userID, "bot-id")
        XCTAssertEqual(result.userName, "Meeting Bot")
        XCTAssertEqual(result.parentPage.id, parentID.uuidString.lowercased())
        XCTAssertEqual(result.parentPageTitle, "团队会议库")
        let requests = await httpClient.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.notion.com/v1/users/me")
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://api.notion.com/v1/pages/\(parentID.uuidString)"
        )
        for request in requests {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer test-token"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Notion-Version"),
                "2026-03-11"
            )
        }
    }

    func testCreatesChildPageAndAppendsNotionBlocks() async throws {
        let parentID = UUID()
        let page = NotionPageReference(
            id: "created-page-id",
            url: "https://www.notion.so/created-page-id"
        )
        let httpClient = QueuedNotionHTTPClient(responses: [
            .json([
                "object": "page",
                "id": page.id,
                "url": page.url
            ]),
            .json(["object": "list", "results": []])
        ])
        let client = NotionClient(token: "test-token", httpClient: httpClient)
        let blocks = [
            NotionBlockDraft(kind: .heading2, text: "摘要"),
            NotionBlockDraft(kind: .paragraph, text: "确认路线图")
        ]

        let created = try await client.createPage(
            parentPageID: parentID,
            title: "产品周会"
        )
        try await client.append(blocks: blocks, to: created.id)

        XCTAssertEqual(created, page)
        let requests = await httpClient.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.notion.com/v1/pages")
        let createBody = try Self.jsonBody(requests[0])
        let parent = try XCTUnwrap(createBody["parent"] as? [String: String])
        XCTAssertEqual(parent["type"], "page_id")
        XCTAssertEqual(parent["page_id"], parentID.uuidString)
        XCTAssertTrue(String(data: requests[0].httpBody ?? Data(), encoding: .utf8)?.contains("产品周会") == true)

        XCTAssertEqual(requests[1].httpMethod, "PATCH")
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://api.notion.com/v1/blocks/created-page-id/children"
        )
        let appendBody = try Self.jsonBody(requests[1])
        XCTAssertEqual((appendBody["children"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(appendBody["after"])
    }

    func testMapsActionableStatusesAndTimeoutWithoutLeakingTokenOrBody() async throws {
        let cases: [(Int, NotionClientError)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .pageNotFound),
            (429, .rateLimited),
            (503, .server(503))
        ]

        for (status, expected) in cases {
            let httpClient = QueuedNotionHTTPClient(responses: [
                .failure(HTTPClientError.unacceptableStatus(status))
            ])
            let token = "secret-token-\(status)"
            let client = NotionClient(token: token, httpClient: httpClient)
            do {
                _ = try await client.testConnection(parentPageID: UUID())
                XCTFail("Expected status \(status)")
            } catch {
                XCTAssertEqual(error as? NotionClientError, expected)
                XCTAssertFalse(String(describing: error).contains(token))
                XCTAssertFalse(String(describing: error).contains("response-secret"))
            }
        }

        let timeoutClient = QueuedNotionHTTPClient(responses: [
            .failure(URLError(.timedOut))
        ])
        let client = NotionClient(token: "secret-token", httpClient: timeoutClient)
        do {
            _ = try await client.testConnection(parentPageID: UUID())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? NotionClientError, .timeout)
        }
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private actor QueuedNotionHTTPClient: HTTPClient {
    struct Response: @unchecked Sendable {
        let result: Result<Data, Error>

        static func json(_ object: Any) -> Response {
            Response(result: Result { try JSONSerialization.data(withJSONObject: object) })
        }

        static func failure(_ error: Error) -> Response {
            Response(result: .failure(error))
        }
    }

    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = responses.removeFirst()
        let data = try response.result.get()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, httpResponse)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
