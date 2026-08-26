import Foundation
import SwiftData

enum DetailedMinutesRecordError: Error, Equatable, Sendable {
    case invalidEncodedField(String)
}

@Model
final class DetailedMinutesRecord {
    @Attribute(.unique) var id: UUID
    var overview: String
    var sectionsData: Data
    var decisionsData: Data
    var actionItemsData: Data
    var openQuestionsData: Data
    var model: String
    var promptVersion: Int
    var createdAt: Date
    var contentRevisionBacking: Int?
    var archiveStateRawValue: String?
    var archivedContentRevision: Int?
    var lastArchiveErrorCode: String?
    var isManuallyEditedBacking: Bool?
    var meeting: MeetingRecord?

    var sections: [DetailedMinutesSection] {
        get throws {
            try Self.decode(
                [DetailedMinutesSection].self,
                from: sectionsData,
                field: "sections"
            )
        }
    }

    var decisions: [String] {
        get throws {
            try Self.decode(
                [String].self,
                from: decisionsData,
                field: "decisions"
            )
        }
    }

    var actionItems: [ActionItem] {
        get throws {
            try Self.decode(
                [ActionItem].self,
                from: actionItemsData,
                field: "actionItems"
            )
        }
    }

    var openQuestions: [String] {
        get throws {
            try Self.decode(
                [String].self,
                from: openQuestionsData,
                field: "openQuestions"
            )
        }
    }

    var contentRevision: Int {
        get { max(0, contentRevisionBacking ?? 0) }
        set { contentRevisionBacking = max(0, newValue) }
    }

    var archiveState: MeetingDocumentArchiveState {
        get {
            archiveStateRawValue
                .flatMap(MeetingDocumentArchiveState.init(rawValue:))
                ?? .localOnly
        }
        set { archiveStateRawValue = newValue.rawValue }
    }

    var isManuallyEdited: Bool {
        get { isManuallyEditedBacking ?? false }
        set { isManuallyEditedBacking = newValue }
    }

    init(
        id: UUID = UUID(),
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        createdAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) throws {
        let encoded = try Self.encode(generated)
        self.id = id
        overview = generated.overview
        sectionsData = encoded.sections
        decisionsData = encoded.decisions
        actionItemsData = encoded.actionItems
        openQuestionsData = encoded.openQuestions
        self.model = model
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        contentRevisionBacking = 1
        archiveStateRawValue = MeetingDocumentArchiveState.localOnly.rawValue
        archivedContentRevision = nil
        lastArchiveErrorCode = nil
        isManuallyEditedBacking = false
        self.meeting = meeting
    }

    init(
        id: UUID = UUID(),
        overview: String,
        sectionsData: Data,
        decisionsData: Data,
        actionItemsData: Data,
        openQuestionsData: Data,
        model: String,
        promptVersion: Int,
        createdAt: Date,
        contentRevision: Int,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.overview = overview
        self.sectionsData = sectionsData
        self.decisionsData = decisionsData
        self.actionItemsData = actionItemsData
        self.openQuestionsData = openQuestionsData
        self.model = model
        self.promptVersion = promptVersion
        self.createdAt = createdAt
        contentRevisionBacking = contentRevision
        archiveStateRawValue = MeetingDocumentArchiveState.localOnly.rawValue
        archivedContentRevision = nil
        lastArchiveErrorCode = nil
        isManuallyEditedBacking = false
        self.meeting = meeting
    }

    static func encode(
        _ generated: GeneratedDetailedMinutes
    ) throws -> EncodedDetailedMinutes {
        let encoder = JSONEncoder()
        return EncodedDetailedMinutes(
            sections: try encoder.encode(generated.sections),
            decisions: try encoder.encode(generated.decisions),
            actionItems: try encoder.encode(generated.actionItems),
            openQuestions: try encoder.encode(generated.openQuestions)
        )
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        field: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DetailedMinutesRecordError.invalidEncodedField(field)
        }
    }
}

struct EncodedDetailedMinutes {
    let sections: Data
    let decisions: Data
    let actionItems: Data
    let openQuestions: Data
}
