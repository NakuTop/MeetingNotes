import Foundation
import SwiftData
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingDocumentsUseCaseTests: XCTestCase {
    func testOrdinaryGenerationCannotOverwriteManualSummary() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: Self.summary,
            model: "old-model"
        )
        let manual = GeneratedMeetingSummary(
            suggestedTitle: "人工标题",
            overview: "人工总结",
            keyPoints: ["人工重点"],
            decisions: ["人工决定"],
            actionItems: [
                ActionItem(task: "人工任务", owner: "小李", dueDate: nil)
            ],
            bookmarkInsights: ["人工书签"]
        )
        try fixture.repository.updateSummaryManually(
            meetingID: meetingID,
            value: manual
        )
        let beforeRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision

        await assertRepositoryThrows(.manualEditProtected(.summary)) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, manual.overview)
        XCTAssertTrue(meeting.summary?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, beforeRevision)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testConfirmedRegenerationCanReplaceManualSummary() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: Self.summary,
            model: "old-model"
        )
        try fixture.repository.updateSummaryManually(
            meetingID: meetingID,
            value: GeneratedMeetingSummary(
                suggestedTitle: "人工标题",
                overview: "人工总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            )
        )
        let beforeRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary,
            replacingManualEdits: true
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, Self.summary.overview)
        XCTAssertFalse(meeting.summary?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, beforeRevision + 1)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testGenerationStartedBeforeLaterEditIsRejectedAsStale()
        async throws {
        let fixture = try makeFixture(
            notionEnabled: false,
            blockSummaryGeneration: true
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: Self.summary,
            model: "old-model"
        )
        let observedRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision
        let generation = Task {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary,
                replacingManualEdits: true
            )
        }
        await fixture.summaryGenerator.waitUntilStarted()
        let laterEdit = GeneratedMeetingSummary(
            suggestedTitle: "稍后人工标题",
            overview: "生成进行中的人工修改",
            keyPoints: ["必须保留"],
            decisions: [],
            actionItems: [],
            bookmarkInsights: []
        )
        try fixture.repository.updateSummaryManually(
            meetingID: meetingID,
            value: laterEdit
        )
        await fixture.summaryGenerator.finishBlockingCall()

        do {
            try await generation.value
            XCTFail("Expected stale revision rejection")
        } catch {
            XCTAssertEqual(
                error as? MeetingDocumentRepositoryError,
                .staleMeetingContentRevision(
                    expected: observedRevision,
                    actual: observedRevision + 1
                )
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, laterEdit.overview)
        XCTAssertTrue(meeting.summary?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, observedRevision + 1)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testOrdinaryGenerationCannotOverwriteManualMinutes() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: Self.minutes,
            model: "old-model",
            promptVersion: 1
        )
        let manual = Self.detailedMinutes(overview: "人工纪要")
        try fixture.repository.updateDetailedMinutesManually(
            meetingID: meetingID,
            value: manual
        )
        let beforeRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision

        await assertRepositoryThrows(.manualEditProtected(.detailedMinutes)) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .detailedMinutes
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.detailedMinutes?.overview, manual.overview)
        XCTAssertTrue(meeting.detailedMinutes?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, beforeRevision)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testConfirmedRegenerationCanReplaceManualMinutes() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: Self.minutes,
            model: "old-model",
            promptVersion: 1
        )
        try fixture.repository.updateDetailedMinutesManually(
            meetingID: meetingID,
            value: Self.detailedMinutes(overview: "人工纪要")
        )
        let beforeRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes,
            replacingManualEdits: true
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.detailedMinutes?.overview, Self.minutes.overview)
        XCTAssertFalse(meeting.detailedMinutes?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, beforeRevision + 1)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testMinutesGenerationStartedBeforeLaterEditIsRejectedAsStale()
        async throws {
        let fixture = try makeFixture(
            notionEnabled: false,
            blockMinutesGeneration: true
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: Self.minutes,
            model: "old-model",
            promptVersion: 1
        )
        let observedRevision = try fixture.repository.meeting(
            id: meetingID
        ).contentRevision
        let generation = Task {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .detailedMinutes,
                replacingManualEdits: true
            )
        }
        await fixture.minutesGenerator.waitUntilStarted()
        let laterEdit = Self.detailedMinutes(
            overview: "生成进行中的人工纪要"
        )
        try fixture.repository.updateDetailedMinutesManually(
            meetingID: meetingID,
            value: laterEdit
        )
        await fixture.minutesGenerator.finishBlockingCall()

        do {
            try await generation.value
            XCTFail("Expected stale revision rejection")
        } catch {
            XCTAssertEqual(
                error as? MeetingDocumentRepositoryError,
                .staleMeetingContentRevision(
                    expected: observedRevision,
                    actual: observedRevision + 1
                )
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.detailedMinutes?.overview, laterEdit.overview)
        XCTAssertTrue(meeting.detailedMinutes?.isManuallyEdited == true)
        XCTAssertEqual(meeting.contentRevision, observedRevision + 1)
        XCTAssertEqual(meeting.state, .summaryReady)
    }

    func testExistentialManagerReceivesExplicitReplacementIntent()
        async throws {
        let spy = ReplacementIntentDocumentManagerSpy()
        let manager: any MeetingDocumentManaging = spy

        try await manager.generate(
            meetingID: UUID(),
            kind: .summary,
            replacingManualEdits: true
        )

        XCTAssertEqual(spy.receivedReplacingManualEdits, true)
    }

    func testOperationCallbackReportsGenerationOnly()
        async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        let manager: any MeetingDocumentManaging = fixture.useCase
        var operations: [MeetingDocumentOperation] = []

        try await manager.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        ) { operations.append($0) }

        XCTAssertEqual(operations, [.generating(.detailedMinutes)])
    }

    func testGenerateNeverArchivesAutomaticallyEvenWhenNotionEnabled()
        async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, Self.summary.overview)
        XCTAssertNil(meeting.detailedMinutes)
        XCTAssertEqual(meeting.summary?.archiveState, .localOnly)
        XCTAssertNil(meeting.summary?.archivedContentRevision)
        XCTAssertEqual(meeting.state, .summaryReady)
        let summaryCalls = await fixture.summaryGenerator.callCount()
        let minutesCalls = await fixture.minutesGenerator.callCount()
        XCTAssertEqual(summaryCalls, 1)
        XCTAssertEqual(minutesCalls, 0)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertTrue(fixture.archiver.statesAtCall.isEmpty)
    }

    func testDetailedGenerationAlsoRemainsLocalUntilExplicitSync() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertNil(meeting.summary)
        XCTAssertEqual(meeting.detailedMinutes?.overview, Self.minutes.overview)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .localOnly)
        XCTAssertNil(meeting.detailedMinutes?.archivedContentRevision)
        XCTAssertEqual(meeting.state, .summaryReady)
        let summaryCalls = await fixture.summaryGenerator.callCount()
        let minutesCalls = await fixture.minutesGenerator.callCount()
        XCTAssertEqual(summaryCalls, 0)
        XCTAssertEqual(minutesCalls, 1)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
    }

    func testExplicitSyncBuildsSummaryMinutesAndCanonicalTranscriptTogether()
        async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(meetingID: meetingID, kind: .summary)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )
        try fixture.repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "张三"
        )
        let noteID = UUID()
        let screenshotID = UUID()
        try fixture.repository.upsertNote(
            meetingID: meetingID,
            id: noteID,
            timestamp: 7,
            text: "  记录风险项  ",
            sequenceIndex: 0
        )
        try fixture.repository.appendScreenshot(
            meetingID: meetingID,
            id: screenshotID,
            timestamp: 9,
            relativePath:
                "\(meetingID.uuidString)/screenshots/private-source.png",
            pixelWidth: 1_200,
            pixelHeight: 800,
            byteCount: 200,
            sequenceIndex: 0
        )
        let snapshotRevision = try fixture.repository
            .meeting(id: meetingID).contentRevision

        try await fixture.useCase.syncToNotion(meetingID: meetingID)

        let content = try XCTUnwrap(fixture.archiver.contents.only)
        XCTAssertEqual(content.contentRevision, snapshotRevision)
        XCTAssertEqual(content.summary?.overview, Self.summary.overview)
        XCTAssertEqual(content.detailedMinutes?.overview, Self.minutes.overview)
        XCTAssertEqual(content.documentKinds, [.summary, .detailedMinutes])
        XCTAssertEqual(content.bookmarks.count, 1)
        XCTAssertEqual(content.transcripts.map(\.text), ["确认下周启动"])
        XCTAssertEqual(content.transcripts.map(\.speakerLabel), ["张三"])
        XCTAssertEqual(content.userNotes.map(\.id), [noteID])
        XCTAssertEqual(content.userNotes.map(\.text), ["记录风险项"])
        XCTAssertEqual(content.screenshots.map(\.id), [screenshotID])
        XCTAssertEqual(content.screenshots.map(\.timestamp), [9])
        XCTAssertNil(content.screenshots.only?.fileUploadID)
        XCTAssertFalse(
            String(describing: content).contains("private-source.png")
        )
        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.notionSyncState, .synced)
        XCTAssertEqual(meeting.notionSyncedContentRevision, snapshotRevision)
        XCTAssertNil(meeting.notionSyncErrorCode)
    }

    func testDisabledNotionKeepsGeneratedDocumentLocal() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        try fixture.credentials.delete(.notionToken)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .localOnly)
        XCTAssertEqual(meeting.state, .summaryReady)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
    }

    func testDisabledNotionRetryArchiveIsNoOpAtUseCaseBoundary() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )

        try await fixture.useCase.retryArchive(
            meetingID: meetingID,
            kind: .summary
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .localOnly)
        XCTAssertEqual(meeting.state, .summaryReady)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertEqual(fixture.useCase.operation, .idle)
    }

    func testKindsCoexistAndRegenerateIndependently() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(meetingID: meetingID, kind: .summary)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )
        let summaryID = try XCTUnwrap(
            fixture.repository.meeting(id: meetingID).summary?.id
        )
        let minutesID = try XCTUnwrap(
            fixture.repository.meeting(id: meetingID).detailedMinutes?.id
        )

        try await fixture.useCase.generate(meetingID: meetingID, kind: .summary)

        var meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.id, summaryID)
        XCTAssertEqual(meeting.summary?.contentRevision, 2)
        XCTAssertEqual(meeting.detailedMinutes?.id, minutesID)
        XCTAssertEqual(meeting.detailedMinutes?.contentRevision, 1)

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )
        meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.contentRevision, 2)
        XCTAssertEqual(meeting.detailedMinutes?.contentRevision, 2)
    }

    func testDetailedInputIsSanitizedSpeakerLabeledAndStablyOrdered() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting(mode: .online)
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 5,
            end: 7,
            text: "<|zh|> 后说 <|unfinished",
            speakerID: "remote-2",
            source: .system,
            sequence: 3
        )
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 1,
            end: 3,
            text: " 先说 ",
            speakerID: "me",
            source: .microphone,
            sequence: 2
        )
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 1,
            end: 2,
            text: "同时更早",
            speakerID: "raw-secret-id",
            source: .system,
            sequence: 1
        )
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 8,
            end: 9,
            text: "<|endoftext|>",
            speakerID: "remote-1",
            source: .system,
            sequence: 4
        )

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )

        let capturedInput = await fixture.minutesGenerator.lastInput()
        let input = try XCTUnwrap(capturedInput)
        XCTAssertEqual(input.transcripts.map(\.text), [
            "同时更早", "先说", "后说",
        ])
        XCTAssertEqual(input.transcripts.map(\.speakerLabel), [
            nil, "我", "远端 2",
        ])
        XCTAssertFalse(
            input.transcripts.compactMap(\.speakerLabel)
                .contains("raw-secret-id")
        )
    }

    func testDocumentInputBuilderUsesCanonicalCorrectedText() throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        let meeting = try fixture.repository.meeting(id: meetingID)
        let transcript = try XCTUnwrap(meeting.transcripts.first)
        let correction = TranscriptCorrectionRecord(
            anchorStartTime: transcript.startTime,
            anchorEndTime: transcript.endTime,
            source: transcript.source,
            originalText: transcript.text,
            replacementText: "确认下周正式启动",
            transcriptIDs: [transcript.id],
            meeting: meeting
        )
        meeting.transcriptCorrections.append(correction)

        let input = MeetingDocumentInputBuilder.inputs(for: meeting)

        XCTAssertEqual(input.transcripts.map(\.text), ["确认下周正式启动"])
        XCTAssertEqual(input.bookmarks.map(\.excerpt), ["确认下周正式启动"])
    }

    func testDocumentInputsIncludeSanitizedOrderedNotesButNoScreenshots()
        async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.upsertNote(
            meetingID: meetingID,
            id: UUID(),
            timestamp: 8,
            text: "  后一条用户笔记  ",
            sequenceIndex: 1
        )
        try fixture.repository.upsertNote(
            meetingID: meetingID,
            id: UUID(),
            timestamp: 2,
            text: "先一条用户笔记",
            sequenceIndex: 0
        )
        try fixture.repository.upsertNote(
            meetingID: meetingID,
            id: UUID(),
            timestamp: 4,
            text: "  \n  ",
            sequenceIndex: 2
        )
        try fixture.repository.appendScreenshot(
            meetingID: meetingID,
            id: UUID(),
            timestamp: 3,
            relativePath:
                "\(meetingID.uuidString)/screenshots/secret-shot.png",
            pixelWidth: 999,
            pixelHeight: 777,
            byteCount: 123,
            sequenceIndex: 0
        )
        let meeting = try fixture.repository.meeting(id: meetingID)

        let built = MeetingDocumentInputBuilder.inputs(for: meeting)

        XCTAssertEqual(built.userNotes.map(\.timestamp), [2, 8])
        XCTAssertEqual(
            built.userNotes.map(\.text),
            ["先一条用户笔记", "后一条用户笔记"]
        )
        XCTAssertFalse(String(describing: built).contains("secret-shot.png"))

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )
        let summaryInput = await fixture.summaryGenerator.lastInput()
        let minutesInput = await fixture.minutesGenerator.lastInput()
        XCTAssertEqual(summaryInput?.userNotes, built.userNotes)
        XCTAssertEqual(minutesInput?.userNotes, built.userNotes)
    }

    func testCustomSpeakerNamesReachBothGeneratedDocumentInputs() async throws {
        let fixture = try makeFixture(notionEnabled: false)
        let meetingID = try fixture.makeMeeting(mode: .online)
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "第一段",
            speakerID: "remote-2",
            source: .system,
            sequence: 0
        )
        try fixture.addTranscript(
            meetingID: meetingID,
            start: 3,
            end: 5,
            text: "第二段",
            speakerID: "remote-2",
            source: .system,
            sequence: 1
        )
        try fixture.repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "remote-2",
            displayName: "张老师"
        )

        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )

        let capturedSummaryInput = await fixture.summaryGenerator.lastInput()
        let capturedMinutesInput = await fixture.minutesGenerator.lastInput()
        let summaryInput = try XCTUnwrap(capturedSummaryInput)
        let minutesInput = try XCTUnwrap(capturedMinutesInput)
        XCTAssertEqual(
            summaryInput.transcripts.map(\.speakerLabel),
            ["张老师", "张老师"]
        )
        XCTAssertEqual(
            minutesInput.transcripts.map(\.speakerLabel),
            ["张老师", "张老师"]
        )
    }

    func testGenerationFailurePreservesOldDocumentAndStableState() async throws {
        let fixture = try makeFixture(
            summaryResult: .failure(DeepSeekClientError.unauthorized),
            notionEnabled: false
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveSummary(
            meetingID: meetingID,
            overview: "旧总结",
            keyPoints: [],
            decisions: [],
            structuredActionItems: [],
            bookmarkInsights: [],
            model: "old"
        )
        try fixture.repository.updateMeetingState(id: meetingID, state: .archived)

        await assertThrows(.generationFailed(.summary)) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, "旧总结")
        XCTAssertEqual(meeting.summary?.contentRevision, 1)
        XCTAssertEqual(meeting.state, .archived)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
    }

    func testLocalSaveFailurePreservesOldDocumentAndStableState() async throws {
        let failure = DocumentSaveFailureController()
        let fixture = try makeFixture(
            notionEnabled: false,
            saveFailureController: failure
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try fixture.repository.saveSummary(
            meetingID: meetingID,
            overview: "旧总结",
            keyPoints: [],
            decisions: [],
            structuredActionItems: [],
            bookmarkInsights: [],
            model: "old"
        )
        try fixture.repository.updateMeetingState(
            id: meetingID,
            state: .summaryReady
        )
        failure.fail(afterSuccessfulSaves: 1)

        await assertThrows(.localPersistenceFailed) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, "旧总结")
        XCTAssertEqual(meeting.summary?.contentRevision, 1)
        XCTAssertEqual(meeting.state, .summaryReady)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
    }

    func testExplicitSyncFailureKeepsLocalDocumentAndRetryDoesNotGenerate()
        async throws {
        let fixture = try makeFixture(
            archiveResults: [
                .failure(NotionClientError.rateLimited),
                .success(()),
            ]
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )

        await assertThrows(.archiveFailed(.detailedMinutes)) {
            try await fixture.useCase.syncToNotion(meetingID: meetingID)
        }

        var meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.detailedMinutes?.overview, Self.minutes.overview)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .localOnly)
        XCTAssertEqual(meeting.notionSyncState, .failed)
        XCTAssertEqual(
            meeting.notionSyncErrorCode,
            MeetingDocumentsUseCase.syncFailureCode
        )
        XCTAssertEqual(meeting.state, .summaryReady)

        try await fixture.useCase.syncToNotion(meetingID: meetingID)

        meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.notionSyncState, .synced)
        XCTAssertEqual(
            meeting.notionSyncedContentRevision,
            meeting.contentRevision
        )
        XCTAssertNil(meeting.notionSyncErrorCode)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .localOnly)
        XCTAssertEqual(meeting.state, .summaryReady)
        let summaryCalls = await fixture.summaryGenerator.callCount()
        let minutesCalls = await fixture.minutesGenerator.callCount()
        XCTAssertEqual(summaryCalls, 0)
        XCTAssertEqual(minutesCalls, 1)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertEqual(fixture.archiver.contents.count, 2)
    }

    func testMissingNotionCredentialLeavesGeneratedDocumentLocal()
        async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )
        try fixture.credentials.delete(.notionToken)

        await assertThrows(.missingNotionCredential) {
            try await fixture.useCase.syncToNotion(meetingID: meetingID)
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, Self.summary.overview)
        XCTAssertEqual(meeting.summary?.archiveState, .localOnly)
        XCTAssertEqual(meeting.notionSyncState, .localOnly)
        XCTAssertNil(meeting.notionSyncErrorCode)
        XCTAssertEqual(meeting.state, .summaryReady)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertTrue(fixture.archiver.contents.isEmpty)
    }

    func testSyncStateSaveFailureNeverLeavesMeetingSyncing() async throws {
        let failure = DocumentSaveFailureController()
        let fixture = try makeFixture(saveFailureController: failure)
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .summary
        )
        failure.fail(afterSuccessfulSaves: 0)

        await assertThrows(.localPersistenceFailed) {
            try await fixture.useCase.syncToNotion(meetingID: meetingID)
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .localOnly)
        XCTAssertEqual(meeting.notionSyncState, .localOnly)
        XCTAssertNil(meeting.notionSyncErrorCode)
        XCTAssertEqual(meeting.state, .summaryReady)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertTrue(fixture.archiver.contents.isEmpty)
    }

    func testGenerationCancellationRestoresStableStateAndPropagatesOriginalError()
        async throws {
        for cancellation in [
            CancellationError() as Error,
            URLError(.cancelled) as Error,
        ] {
            let fixture = try makeFixture(
                summaryResult: .failure(cancellation),
                notionEnabled: false
            )
            let meetingID = try fixture.makeMeeting()
            try fixture.addFinalTranscript(to: meetingID)
            try fixture.repository.updateMeetingState(
                id: meetingID,
                state: .archived
            )

            do {
                try await fixture.useCase.generate(
                    meetingID: meetingID,
                    kind: .summary
                )
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch {
                XCTFail("Expected original cancellation, got \(error)")
            }

            XCTAssertEqual(
                try fixture.repository.meeting(id: meetingID).state,
                .archived
            )
            XCTAssertEqual(fixture.useCase.operation, .idle)
        }
    }

    func testArchiveCancellationRestoresDocumentMetadataAndMeetingState()
        async throws {
        for cancellation in [
            CancellationError() as Error,
            URLError(.cancelled) as Error,
        ] {
            let fixture = try makeFixture(
                archiveResults: [.failure(cancellation)]
            )
            let meetingID = try fixture.makeMeeting()
            try fixture.addFinalTranscript(to: meetingID)
            try fixture.repository.saveSummary(
                meetingID: meetingID,
                overview: "已保存",
                keyPoints: [],
                decisions: [],
                structuredActionItems: [],
                bookmarkInsights: [],
                model: "old"
            )
            let summary = try XCTUnwrap(
                fixture.repository.meeting(id: meetingID).summary
            )
            summary.archiveState = .failed
            summary.lastArchiveErrorCode = "previous_error"
            try fixture.repository.updateMeetingState(
                id: meetingID,
                state: .summaryReady
            )

            do {
                try await fixture.useCase.retryArchive(
                    meetingID: meetingID,
                    kind: .summary
                )
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch {
                XCTFail("Expected original cancellation, got \(error)")
            }

            let meeting = try fixture.repository.meeting(id: meetingID)
            XCTAssertEqual(meeting.summary?.archiveState, .failed)
            XCTAssertEqual(
                meeting.summary?.lastArchiveErrorCode,
                "previous_error"
            )
            XCTAssertEqual(meeting.state, .summaryReady)
        }
    }

    func testGenerationSnapshotsModelForRequestAndPersistence() async throws {
        let fixture = try makeFixture(
            notionEnabled: false,
            blockSummaryGeneration: true
        )
        fixture.settings.deepSeekModel = "model-before"
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        let generation = Task {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }
        await fixture.summaryGenerator.waitUntilStarted()
        fixture.settings.deepSeekModel = "model-after"
        await fixture.summaryGenerator.finishBlockingCall()
        try await generation.value

        let models = await fixture.summaryGenerator.requestedModels()
        XCTAssertEqual(models, ["model-before"])
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).summary?.model,
            "model-before"
        )
    }

    func testSingleOperationSlotRejectsConcurrentGenerationForAnotherMeeting()
        async throws {
        let fixture = try makeFixture(
            notionEnabled: false,
            blockSummaryGeneration: true
        )
        let firstID = try fixture.makeMeeting()
        let secondID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: firstID)
        try fixture.addFinalTranscript(to: secondID)

        let first = Task {
            try await fixture.useCase.generate(
                meetingID: firstID,
                kind: .summary
            )
        }
        await fixture.summaryGenerator.waitUntilStarted()

        await assertThrows(.operationInProgress) {
            try await fixture.useCase.generate(
                meetingID: secondID,
                kind: .detailedMinutes
            )
        }

        await fixture.summaryGenerator.finishBlockingCall()
        try await first.value
        XCTAssertNil(
            try fixture.repository.meeting(id: secondID).detailedMinutes
        )
    }

    func testRestoreRetriesOnceAndDoesNotLeaveSummarizing() async throws {
        let failure = DocumentSaveFailureController()
        let fixture = try makeFixture(
            summaryResult: .failure(DeepSeekClientError.unauthorized),
            notionEnabled: false,
            saveFailureController: failure
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        failure.fail(afterSuccessfulSaves: 1)

        await assertThrows(.generationFailed(.summary)) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }

        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .ready
        )
    }

    func testPendingRecoveryIsAppliedOnNextOperationAfterTwoRestoreFailures()
        async throws {
        let failure = DocumentSaveFailureController()
        let fixture = try makeFixture(
            summaryResult: .failure(DeepSeekClientError.unauthorized),
            notionEnabled: false,
            saveFailureController: failure
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        failure.fail(afterSuccessfulSaves: 1, consecutiveFailures: 2)

        await assertThrows(.localPersistenceFailed) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .summarizing
        )
        XCTAssertEqual(fixture.useCase.operation, .idle)

        await assertThrows(.generationFailed(.summary)) {
            try await fixture.useCase.generate(
                meetingID: meetingID,
                kind: .summary
            )
        }
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .ready
        )
    }

    func testMeetingIsArchivedOnlyAfterEveryExistingDocumentIsArchived()
        async throws {
        let fixture = try makeFixture(
            archiveResults: [.success(()), .success(())],
            notionEnabled: false
        )
        let meetingID = try fixture.makeMeeting()
        try fixture.addFinalTranscript(to: meetingID)
        try await fixture.useCase.generate(meetingID: meetingID, kind: .summary)
        try await fixture.useCase.generate(
            meetingID: meetingID,
            kind: .detailedMinutes
        )
        fixture.settings.isNotionArchivingEnabled = true

        try await fixture.useCase.retryArchive(
            meetingID: meetingID,
            kind: .summary
        )

        var meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .archived)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .localOnly)
        XCTAssertEqual(meeting.state, .summaryReady)

        try await fixture.useCase.retryArchive(
            meetingID: meetingID,
            kind: .detailedMinutes
        )

        meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .archived)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .archived)
        XCTAssertEqual(meeting.state, .archived)
    }

    func testRetryArchiveRejectsMissingSelectedDocumentWithoutGeneration() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeMeeting()

        await assertThrows(.missingLocalDocument(.summary)) {
            try await fixture.useCase.retryArchive(
                meetingID: meetingID,
                kind: .summary
            )
        }

        let summaryCalls = await fixture.summaryGenerator.callCount()
        let minutesCalls = await fixture.minutesGenerator.callCount()
        XCTAssertEqual(summaryCalls, 0)
        XCTAssertEqual(minutesCalls, 0)
        XCTAssertTrue(fixture.archiver.kinds.isEmpty)
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .ready
        )
    }

    func testArchivedMeetingRegenerationBecomesLocalAndNeedsExplicitSync()
        async throws {
        for kind in MeetingDocumentKind.allCases {
            let fixture = try makeFixture()
            let meetingID = try fixture.makeMeeting()
            try fixture.addFinalTranscript(to: meetingID)
            try fixture.repository.updateMeetingState(id: meetingID, state: .archived)

            try await fixture.useCase.generate(meetingID: meetingID, kind: kind)

            let meeting = try fixture.repository.meeting(id: meetingID)
            XCTAssertEqual(meeting.state, .summaryReady)
            XCTAssertEqual(meeting.notionSyncState, .localOnly)
            XCTAssertTrue(fixture.archiver.statesAtCall.isEmpty)
            XCTAssertTrue(fixture.archiver.contents.isEmpty)
        }
    }

    func testNoFinalTranscriptRejectsBothKindsWithoutChangingAnything() async throws {
        for kind in MeetingDocumentKind.allCases {
            let fixture = try makeFixture(notionEnabled: false)
            let meetingID = try fixture.makeMeeting()
            try fixture.repository.appendTranscript(
                meetingID: meetingID,
                start: 0,
                end: 1,
                text: "临时",
                isFinal: false
            )

            await assertThrows(.noFinalTranscript) {
                try await fixture.useCase.generate(
                    meetingID: meetingID,
                    kind: kind
                )
            }

            let meeting = try fixture.repository.meeting(id: meetingID)
            XCTAssertNil(meeting.summary)
            XCTAssertNil(meeting.detailedMinutes)
            XCTAssertEqual(meeting.state, .ready)
        }
    }

    func testSharedGateRejectsGenerateAndRetryAgainstEveryExistingOperation()
        async throws {
        for operation in [
            MeetingOperationKind.rename,
            .delete,
            .speakerDiarizationRetry,
            .summarizeArchive,
        ] {
            let gate = MeetingOperationGate()
            let fixture = try makeFixture(operationGate: gate)
            let meetingID = try fixture.makeMeeting()
            try fixture.addFinalTranscript(to: meetingID)
            try fixture.repository.saveSummary(
                meetingID: meetingID,
                overview: "已保存",
                keyPoints: [],
                decisions: [],
                structuredActionItems: [],
                bookmarkInsights: [],
                model: "old"
            )
            XCTAssertTrue(gate.acquire(operation, for: meetingID))

            await assertThrows(.operationInProgress) {
                try await fixture.useCase.generate(
                    meetingID: meetingID,
                    kind: .summary
                )
            }
            await assertThrows(.operationInProgress) {
                try await fixture.useCase.retryArchive(
                    meetingID: meetingID,
                    kind: .summary
                )
            }
            gate.release(operation, for: meetingID)
        }
    }

    private func makeFixture(
        summaryResult: Result<GeneratedMeetingSummary, Error> = .success(summary),
        minutesResult: Result<GeneratedDetailedMinutes, Error> = .success(minutes),
        archiveResults: [Result<Void, Error>] = [.success(())],
        notionEnabled: Bool = true,
        operationGate: MeetingOperationGate = MeetingOperationGate(),
        saveFailureController: DocumentSaveFailureController? = nil,
        blockSummaryGeneration: Bool = false,
        blockMinutesGeneration: Bool = false
    ) throws -> DocumentFixture {
        let repository = try MeetingRepository.inMemory { context in
            if saveFailureController?.consumeFailure() == true {
                throw DocumentInjectedError.persistence
            }
            try context.save()
        }
        let credentials = DocumentCredentialStore()
        try credentials.save("deepseek-key", for: .deepSeekAPIKey)
        try credentials.save("notion-token", for: .notionToken)
        let suiteName = "MeetingDocumentsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        settings.deepSeekModel = "deepseek-chat"
        settings.isNotionArchivingEnabled = notionEnabled
        settings.notionParentPageURL =
            "https://www.notion.so/Parent-1234567890abcdef1234567890abcdef"
        let summaryGenerator = DocumentSummaryGeneratorSpy(
            result: summaryResult,
            shouldBlock: blockSummaryGeneration
        )
        let minutesGenerator = DocumentMinutesGeneratorSpy(
            result: minutesResult,
            shouldBlock: blockMinutesGeneration
        )
        let archiver = DocumentArchiverSpy(
            repository: repository,
            results: archiveResults
        )
        let useCase = MeetingDocumentsUseCase(
            repository: repository,
            credentialStore: credentials,
            settingsStore: settings,
            summaryGenerator: summaryGenerator,
            detailedMinutesGenerator: minutesGenerator,
            archiver: archiver,
            operationGate: operationGate
        )
        return DocumentFixture(
            repository: repository,
            credentials: credentials,
            settings: settings,
            useCase: useCase,
            summaryGenerator: summaryGenerator,
            minutesGenerator: minutesGenerator,
            archiver: archiver
        )
    }

    private func assertThrows(
        _ expected: MeetingDocumentsError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MeetingDocumentsError, expected)
        }
    }

    private func assertRepositoryThrows(
        _ expected: MeetingDocumentRepositoryError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MeetingDocumentRepositoryError, expected)
        }
    }

    private static let summary = GeneratedMeetingSummary(
        suggestedTitle: "项目启动会",
        overview: "确认启动计划",
        keyPoints: ["下周启动"],
        decisions: ["按计划执行"],
        actionItems: [ActionItem(task: "准备排期", owner: "小王", dueDate: "周五")],
        bookmarkInsights: ["核心决定"]
    )

    private static let minutes = GeneratedDetailedMinutes(
        overview: "完整纪要概览",
        sections: [
            DetailedMinutesSection(
                title: "方案讨论",
                timeRange: "00:00–00:30",
                speakers: ["我", "远端 1"],
                content: "团队比较了两个方案并选择 A。"
            ),
        ],
        decisions: ["选择 A"],
        actionItems: [ActionItem(task: "落实 A", owner: "小王", dueDate: nil)],
        openQuestions: ["预算待确认"]
    )

    private static func detailedMinutes(
        overview: String
    ) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: minutes.sections,
            decisions: minutes.decisions,
            actionItems: minutes.actionItems,
            openQuestions: minutes.openQuestions
        )
    }
}

@MainActor
private final class ReplacementIntentDocumentManagerSpy:
    MeetingDocumentManaging {
    private(set) var receivedReplacingManualEdits: Bool?

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws {
        _ = meetingID
        _ = kind
        receivedReplacingManualEdits = replacingManualEdits
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = meetingID
        _ = kind
    }

    func syncToNotion(meetingID: UUID) async throws {
        _ = meetingID
    }
}

@MainActor
private struct DocumentFixture {
    let repository: MeetingRepository
    let credentials: DocumentCredentialStore
    let settings: AppSettingsStore
    let useCase: MeetingDocumentsUseCase
    let summaryGenerator: DocumentSummaryGeneratorSpy
    let minutesGenerator: DocumentMinutesGeneratorSpy
    let archiver: DocumentArchiverSpy

    func makeMeeting(mode: MeetingMode = .offline) throws -> UUID {
        let id = try repository.createMeeting(
            mode: mode,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.finalizeMeeting(
            id: id,
            endedAt: Date(timeIntervalSince1970: 1_120),
            activeDuration: 120
        )
        return id
    }

    func addFinalTranscript(to meetingID: UUID) throws {
        try addTranscript(
            meetingID: meetingID,
            start: 0,
            end: 5,
            text: "确认下周启动",
            speakerID: "room-1",
            source: .room,
            sequence: 0
        )
        try repository.appendBookmark(meetingID: meetingID, timestamp: 3)
    }

    func addTranscript(
        meetingID: UUID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerID: String?,
        source: TranscriptAudioSource,
        sequence: Int
    ) throws {
        try repository.appendTranscript(
            meetingID: meetingID,
            start: start,
            end: end,
            text: text,
            isFinal: true,
            speakerID: speakerID
        )
        let transcript = try XCTUnwrap(
            repository.meeting(id: meetingID).transcripts.last
        )
        transcript.source = source
        transcript.sequenceIndex = sequence
        try repository.updateMeetingState(
            id: meetingID,
            state: repository.meeting(id: meetingID).state
        )
    }
}

private actor DocumentSummaryGeneratorSpy: MeetingSummaryGenerating {
    let result: Result<GeneratedMeetingSummary, Error>
    private var calls = 0
    private var inputs: [MeetingSummaryInput] = []
    private var models: [String] = []
    private let shouldBlock: Bool
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(
        result: Result<GeneratedMeetingSummary, Error>,
        shouldBlock: Bool = false
    ) {
        self.result = result
        self.shouldBlock = shouldBlock
    }

    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        _ = apiKey
        calls += 1
        inputs.append(input)
        models.append(model)
        if shouldBlock {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }
        return try result.get()
    }

    func callCount() -> Int { calls }
    func lastInput() -> MeetingSummaryInput? { inputs.last }
    func requestedModels() -> [String] { models }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishBlockingCall() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor DocumentMinutesGeneratorSpy: MeetingDetailedMinutesGenerating {
    let result: Result<GeneratedDetailedMinutes, Error>
    private var calls = 0
    private var inputs: [MeetingSummaryInput] = []
    private let shouldBlock: Bool
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(
        result: Result<GeneratedDetailedMinutes, Error>,
        shouldBlock: Bool = false
    ) {
        self.result = result
        self.shouldBlock = shouldBlock
    }

    func detailedMinutes(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedDetailedMinutes {
        _ = apiKey
        _ = model
        calls += 1
        inputs.append(input)
        if shouldBlock {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }
        return try result.get()
    }

    func callCount() -> Int { calls }
    func lastInput() -> MeetingSummaryInput? { inputs.last }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishBlockingCall() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class DocumentArchiverSpy: MeetingDocumentArchiving {
    private let repository: MeetingRepository
    private var results: [Result<Void, Error>]
    private(set) var kinds: [MeetingDocumentKind] = []
    private(set) var statesAtCall: [RecordingState] = []
    private(set) var contents: [NotionMeetingPageContent] = []

    init(
        repository: MeetingRepository,
        results: [Result<Void, Error>]
    ) {
        self.repository = repository
        self.results = results
    }

    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = token
        _ = parentPageID
        kinds.append(kind)
        statesAtCall.append(try repository.meeting(id: meetingID).state)
        guard !results.isEmpty else { throw NotionClientError.transport }
        try results.removeFirst().get()
    }

    func sync(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws {
        _ = token
        _ = parentPageID
        contents.append(content)
        statesAtCall.append(try repository.meeting(id: meetingID).state)
        guard !results.isEmpty else { throw NotionClientError.transport }
        try results.removeFirst().get()
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private final class DocumentCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: String] = [:]

    func value(for key: CredentialKey) throws -> String? { values[key] }
    func save(_ value: String, for key: CredentialKey) throws {
        values[key] = value
    }
    func delete(_ key: CredentialKey) throws { values[key] = nil }
}

private final class DocumentSaveFailureController: @unchecked Sendable {
    private var savesBeforeFailure: Int?
    private var consecutiveFailures = 0

    func fail(
        afterSuccessfulSaves count: Int,
        consecutiveFailures: Int = 1
    ) {
        savesBeforeFailure = count
        self.consecutiveFailures = consecutiveFailures
    }

    func consumeFailure() -> Bool {
        guard let remaining = savesBeforeFailure else { return false }
        if remaining > 0 {
            savesBeforeFailure = remaining - 1
            return false
        }
        consecutiveFailures -= 1
        if consecutiveFailures == 0 {
            savesBeforeFailure = nil
        }
        return true
    }
}

private enum DocumentInjectedError: Error {
    case persistence
}
