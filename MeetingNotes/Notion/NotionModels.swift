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

enum NotionArchiveRunPhase: String, Codable, Equatable, Sendable {
    case appending
    case cleaningUp
}

struct NotionDocumentArchiveRun: Codable, Equatable, Sendable {
    let contentRevision: Int
    var newBlockIDs: [String]
    var oldBlockIDs: [String]
    var nextBatchIndex: Int
    var phase: NotionArchiveRunPhase

    init(
        contentRevision: Int,
        newBlockIDs: [String] = [],
        oldBlockIDs: [String] = [],
        nextBatchIndex: Int = 0,
        phase: NotionArchiveRunPhase = .appending
    ) {
        self.contentRevision = contentRevision
        self.newBlockIDs = newBlockIDs
        self.oldBlockIDs = oldBlockIDs
        self.nextBatchIndex = nextBatchIndex
        self.phase = phase
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
    ) async throws -> [String]

    func archiveBlock(id: String) async throws

    func updatePageTitle(pageID: String, title: String) async throws
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
