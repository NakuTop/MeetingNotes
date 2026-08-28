import Foundation
import SwiftData

enum ArchiveCheckpointCodingError: Error, Equatable, Sendable {
    case invalidData(String)
    case encodingFailed(String)
}

@Model
final class ArchiveCheckpointRecord {
    @Attribute(.unique) var id: UUID
    var notionPageID: String
    var nextSection: String
    var nextBatchIndex: Int
    var metadataBlockIDsData: Data?
    var summaryBlockIDsData: Data?
    var detailedMinutesBlockIDsData: Data?
    var pageBlockIDsData: Data?
    var pageSyncRunData: Data?
    var pendingKindRawValue: String?
    var pendingNewBlockIDsData: Data?
    var pendingOldBlockIDsData: Data?
    var pendingNextBatchIndex: Int?
    var pendingContentRevision: Int?
    var pendingPhaseRawValue: String?
    var pendingRunsData: Data?
    var updatedAt: Date
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        notionPageID: String,
        nextSection: String,
        nextBatchIndex: Int,
        updatedAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.notionPageID = notionPageID
        self.nextSection = nextSection
        self.nextBatchIndex = nextBatchIndex
        metadataBlockIDsData = nil
        summaryBlockIDsData = nil
        detailedMinutesBlockIDsData = nil
        pageBlockIDsData = nil
        pageSyncRunData = nil
        pendingKindRawValue = nil
        pendingNewBlockIDsData = nil
        pendingOldBlockIDsData = nil
        pendingNextBatchIndex = nil
        pendingContentRevision = nil
        pendingPhaseRawValue = nil
        pendingRunsData = nil
        self.updatedAt = updatedAt
        self.meeting = meeting
    }

    var metadataBlockIDs: [String] {
        get throws {
            try Self.decodeIDs(
                metadataBlockIDsData,
                field: "metadataBlockIDsData"
            )
        }
    }

    var pageBlockIDs: [String] {
        get throws {
            try Self.decodeIDs(
                pageBlockIDsData,
                field: "pageBlockIDsData"
            )
        }
    }

    func pageSyncRun() throws -> NotionPageSyncRun? {
        try Self.decode(
            NotionPageSyncRun.self,
            from: pageSyncRunData,
            field: "pageSyncRunData"
        )
    }

    func blockIDs(for kind: MeetingDocumentKind) throws -> [String] {
        switch kind {
        case .summary:
            try Self.decodeIDs(
                summaryBlockIDsData,
                field: "summaryBlockIDsData"
            )
        case .detailedMinutes:
            try Self.decodeIDs(
                detailedMinutesBlockIDsData,
                field: "detailedMinutesBlockIDsData"
            )
        }
    }

    func pendingRun(
        for kind: MeetingDocumentKind
    ) throws -> NotionDocumentArchiveRun? {
        try pendingRuns()[kind.rawValue]
    }

    func setMetadataBlockIDs(_ blockIDs: [String]) throws {
        metadataBlockIDsData = try Self.encode(
            blockIDs,
            field: "metadataBlockIDsData"
        )
    }

    func setPageBlockIDs(_ blockIDs: [String]) throws {
        pageBlockIDsData = try Self.encode(
            blockIDs,
            field: "pageBlockIDsData"
        )
    }

    func setPageSyncRun(_ run: NotionPageSyncRun?) throws {
        pageSyncRunData = try run.map {
            try Self.encode($0, field: "pageSyncRunData")
        }
    }

    func setBlockIDs(
        _ blockIDs: [String],
        for kind: MeetingDocumentKind
    ) throws {
        switch kind {
        case .summary:
            summaryBlockIDsData = try Self.encode(
                blockIDs,
                field: "summaryBlockIDsData"
            )
        case .detailedMinutes:
            detailedMinutesBlockIDsData = try Self.encode(
                blockIDs,
                field: "detailedMinutesBlockIDsData"
            )
        }
    }

    func setPendingRun(
        _ run: NotionDocumentArchiveRun?,
        for kind: MeetingDocumentKind
    ) throws {
        var runs = try pendingRuns()
        runs[kind.rawValue] = run
        let encodedRuns = try runs.isEmpty ? nil : Self.encode(
            runs,
            field: "pendingRunsData"
        )
        let selected: (MeetingDocumentKind, NotionDocumentArchiveRun)?
        if run != nil, let selectedRun = runs[kind.rawValue] {
            selected = (kind, selectedRun)
        } else {
            selected = MeetingDocumentKind.allCases.compactMap { kind in
                runs[kind.rawValue].map { (kind, $0) }
            }.first
        }
        let legacyNewIDsData: Data?
        let legacyOldIDsData: Data?
        if let (_, selectedRun) = selected {
            legacyNewIDsData = try Self.encode(
                selectedRun.newBlockIDs,
                field: "pendingNewBlockIDsData"
            )
            legacyOldIDsData = try Self.encode(
                selectedRun.oldBlockIDs,
                field: "pendingOldBlockIDsData"
            )
        } else {
            legacyNewIDsData = nil
            legacyOldIDsData = nil
        }

        pendingRunsData = encodedRuns
        pendingKindRawValue = selected?.0.rawValue
        pendingNewBlockIDsData = legacyNewIDsData
        pendingOldBlockIDsData = legacyOldIDsData
        pendingNextBatchIndex = selected?.1.nextBatchIndex
        pendingContentRevision = selected?.1.contentRevision
        pendingPhaseRawValue = selected?.1.phase.rawValue
    }

    private func pendingRuns() throws -> [String: NotionDocumentArchiveRun] {
        if pendingRunsData != nil {
            return try Self.decode(
                [String: NotionDocumentArchiveRun].self,
                from: pendingRunsData,
                field: "pendingRunsData"
            ) ?? [:]
        }
        let hasLegacyPendingData = pendingKindRawValue != nil
            || pendingNewBlockIDsData != nil
            || pendingOldBlockIDsData != nil
            || pendingNextBatchIndex != nil
            || pendingContentRevision != nil
            || pendingPhaseRawValue != nil
        guard hasLegacyPendingData else { return [:] }
        guard let rawKind = pendingKindRawValue,
              let kind = MeetingDocumentKind(rawValue: rawKind),
              let contentRevision = pendingContentRevision else {
            throw ArchiveCheckpointCodingError.invalidData(
                "legacyPendingRun"
            )
        }
        let phase: NotionArchiveRunPhase
        if let pendingPhaseRawValue {
            guard let decoded = NotionArchiveRunPhase(
                rawValue: pendingPhaseRawValue
            ) else {
                throw ArchiveCheckpointCodingError.invalidData(
                    "pendingPhaseRawValue"
                )
            }
            phase = decoded
        } else {
            phase = .appending
        }
        return [
            kind.rawValue: NotionDocumentArchiveRun(
                contentRevision: contentRevision,
                newBlockIDs: try Self.decodeIDs(
                    pendingNewBlockIDsData,
                    field: "pendingNewBlockIDsData"
                ),
                oldBlockIDs: try Self.decodeIDs(
                    pendingOldBlockIDsData,
                    field: "pendingOldBlockIDsData"
                ),
                nextBatchIndex: max(0, pendingNextBatchIndex ?? 0),
                phase: phase
            )
        ]
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        field: String
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw ArchiveCheckpointCodingError.encodingFailed(field)
        }
    }

    private static func decodeIDs(
        _ data: Data?,
        field: String
    ) throws -> [String] {
        try decode([String].self, from: data, field: field) ?? []
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data?,
        field: String
    ) throws -> Value? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ArchiveCheckpointCodingError.invalidData(field)
        }
    }
}
