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

struct NotionChildBlockPage: Equatable, Sendable {
    let blockIDs: [String]
    let nextCursor: String?
}

enum NotionPageSyncPhase: String, Codable, Equatable, Sendable {
    case appendingNew
    case rollingBackPartialNew
    case cleaningOld
}

struct NotionPageSyncRun: Codable, Equatable, Sendable {
    let contentRevision: Int
    let snapshotData: Data
    var oldBlockIDs: [String]
    var newBlockIDs: [String]
    var nextBatchIndex: Int
    var phase: NotionPageSyncPhase

    init(
        contentRevision: Int,
        snapshotData: Data,
        oldBlockIDs: [String],
        newBlockIDs: [String] = [],
        nextBatchIndex: Int = 0,
        phase: NotionPageSyncPhase = .appendingNew
    ) {
        self.contentRevision = contentRevision
        self.snapshotData = snapshotData
        self.oldBlockIDs = oldBlockIDs
        self.newBlockIDs = newBlockIDs
        self.nextBatchIndex = nextBatchIndex
        self.phase = phase
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

    func childBlocks(
        pageID: String,
        startCursor: String?
    ) async throws -> NotionChildBlockPage

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws -> [String]

    func archiveBlock(id: String) async throws

    func updatePageTitle(pageID: String, title: String) async throws
}

extension NotionAPIClient {
    func childBlocks(
        pageID: String,
        startCursor: String?
    ) async throws -> NotionChildBlockPage {
        _ = pageID
        _ = startCursor
        throw NotionClientError.invalidResponse
    }
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
