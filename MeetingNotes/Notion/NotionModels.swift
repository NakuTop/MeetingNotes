import Foundation

struct NotionPageReference: Codable, Equatable, Sendable {
    let id: String
    let url: String
}

struct NotionConnectionResult: Equatable, Sendable {
    let userID: String
    let userName: String?
    let parentPage: NotionPageReference
    let parentPageTitle: String

    init(
        userID: String,
        userName: String?,
        parentPage: NotionPageReference,
        parentPageTitle: String = "未命名页面"
    ) {
        self.userID = userID
        self.userName = userName
        self.parentPage = parentPage
        self.parentPageTitle = parentPageTitle
    }
}

protocol NotionAPIClient: Sendable {
    func testConnection(
        parentPageID: UUID
    ) async throws -> NotionConnectionResult

    func createPage(
        parentPageID: UUID,
        title: String
    ) async throws -> NotionPageReference

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws
}

enum NotionClientError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case pageNotFound
    case rateLimited
    case server(Int)
    case http(Int)
    case timeout
    case transport
    case invalidRequest
    case invalidResponse
}
