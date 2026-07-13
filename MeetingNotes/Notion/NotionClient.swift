import Foundation

struct NotionClient: NotionAPIClient, Sendable {
    static let apiVersion = "2026-03-11"

    private let token: String
    private let httpClient: any HTTPClient
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        token: String,
        httpClient: any HTTPClient,
        baseURL: URL = URL(string: "https://api.notion.com/v1")!
    ) {
        self.token = token
        self.httpClient = httpClient
        self.baseURL = baseURL
    }

    func testConnection(
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        let userData = try await perform(
            request(method: "GET", path: ["users", "me"], timeout: 15)
        )
        let user: UserResponse
        do {
            user = try decoder.decode(UserResponse.self, from: userData)
        } catch {
            throw NotionClientError.invalidResponse
        }

        let pageData = try await perform(
            request(
                method: "GET",
                path: ["pages", parentPageID.uuidString],
                timeout: 15
            )
        )
        let page = try decodePage(pageData)
        return NotionConnectionResult(
            userID: user.id,
            userName: user.name,
            parentPage: page
        )
    }

    func createPage(
        parentPageID: UUID,
        title: String
    ) async throws -> NotionPageReference {
        var request = request(method: "POST", path: ["pages"], timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(
                CreatePageRequest(
                    parent: .init(
                        type: "page_id",
                        pageID: parentPageID.uuidString
                    ),
                    properties: .init(
                        title: .init(
                            type: "title",
                            title: [.plain(String(title.prefix(1_900)))]
                        )
                    )
                )
            )
        } catch {
            throw NotionClientError.invalidRequest
        }

        return try decodePage(try await perform(request))
    }

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws {
        guard !blocks.isEmpty, blocks.count <= 100 else {
            throw NotionClientError.invalidRequest
        }
        var request = request(
            method: "PATCH",
            path: ["blocks", pageID, "children"],
            timeout: 30
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(
                AppendBlocksRequest(children: blocks)
            )
        } catch {
            throw NotionClientError.invalidRequest
        }
        _ = try await perform(request)
    }

    private func request(
        method: String,
        path: [String],
        timeout: TimeInterval
    ) -> URLRequest {
        let url = path.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            return try await httpClient.data(for: request).0
        } catch let error as NotionClientError {
            throw error
        } catch HTTPClientError.unacceptableStatus(let status) {
            switch status {
            case 401:
                throw NotionClientError.unauthorized
            case 403:
                throw NotionClientError.forbidden
            case 404:
                throw NotionClientError.pageNotFound
            case 429:
                throw NotionClientError.rateLimited
            case 500...599:
                throw NotionClientError.server(status)
            default:
                throw NotionClientError.http(status)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw NotionClientError.timeout
        } catch {
            throw NotionClientError.transport
        }
    }

    private func decodePage(_ data: Data) throws -> NotionPageReference {
        do {
            return try decoder.decode(NotionPageReference.self, from: data)
        } catch {
            throw NotionClientError.invalidResponse
        }
    }
}

private struct UserResponse: Decodable {
    let id: String
    let name: String?
}

private struct CreatePageRequest: Encodable {
    let parent: Parent
    let properties: Properties

    struct Parent: Encodable {
        let type: String
        let pageID: String

        enum CodingKeys: String, CodingKey {
            case type
            case pageID = "page_id"
        }
    }

    struct Properties: Encodable {
        let title: TitleProperty
    }

    struct TitleProperty: Encodable {
        let type: String
        let title: [PlainRichText]
    }
}

private struct PlainRichText: Encodable {
    let type: String
    let text: TextContent

    static func plain(_ content: String) -> PlainRichText {
        PlainRichText(type: "text", text: TextContent(content: content))
    }

    struct TextContent: Encodable {
        let content: String
    }
}

private struct AppendBlocksRequest: Encodable {
    let children: [NotionBlockDraft]
}
