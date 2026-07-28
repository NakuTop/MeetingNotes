import XCTest
import SwiftData
@testable import MeetingNotes

@MainActor
final class MeetingRepositoryTests: XCTestCase {
    func testTranscriptSourceFallsBackToMixedForNilAndUnknownValues() {
        let transcript = TranscriptRecord(
            startTime: 0,
            endTime: 1,
            text: "旧记录",
            isFinal: true
        )

        XCTAssertNil(transcript.sourceRawValue)
        XCTAssertEqual(transcript.source, .mixed)

        transcript.sourceRawValue = "legacy-unknown-source"

        XCTAssertEqual(transcript.source, .mixed)
    }

    func testLegacyNilSpeakerFieldsFallBackToSafeBusinessDefaults() {
        let meeting = MeetingRecord(
            title: "旧会议",
            mode: .offline,
            state: .ready,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        meeting.speakerDiarizationRequestedBacking = nil
        meeting.speakerProcessingStateRawValue = nil

        XCTAssertFalse(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)

        meeting.speakerProcessingStateRawValue = "legacy-unknown-state"

        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)
    }

    func testCreateMeetingDefaultsSpeakerProcessingToNotRequested() throws {
        let repository = try MeetingRepository.inMemory()

        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertFalse(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerDiarizationRequestedBacking, false)
        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)
        XCTAssertEqual(
            meeting.speakerProcessingStateRawValue,
            SpeakerProcessingState.notRequested.rawValue
        )
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testCreateMeetingSnapshotsRequestedSpeakerDiarizationAsPending() throws {
        let repository = try MeetingRepository.inMemory()

        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            speakerDiarizationRequested: true
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertTrue(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerDiarizationRequestedBacking, true)
        XCTAssertEqual(meeting.speakerProcessingState, .pending)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testMarkSpeakerProcessingStartedTransitionsRequestedMeeting()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            speakerDiarizationRequested: true
        )

        try repository.markSpeakerProcessingStarted(meetingID: id)

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testMarkSpeakerProcessingStartedLeavesUnrequestedAndDegradedStates()
        throws {
        let repository = try MeetingRepository.inMemory()
        let unrequestedID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let degradedID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_001),
            speakerDiarizationRequested: true
        )
        let degraded = try repository.meeting(id: degradedID)
        degraded.speakerProcessingState = .degraded
        degraded.speakerProcessingErrorCode =
            "source_track_write_failed_microphone"
        try repository.updateMeetingState(
            id: degradedID,
            state: degraded.state
        )

        try repository.markSpeakerProcessingStarted(meetingID: unrequestedID)
        try repository.markSpeakerProcessingStarted(meetingID: degradedID)

        let unrequested = try repository.meeting(id: unrequestedID)
        XCTAssertEqual(unrequested.speakerProcessingState, .notRequested)
        XCTAssertNil(unrequested.speakerProcessingErrorCode)
        XCTAssertEqual(degraded.speakerProcessingState, .degraded)
        XCTAssertEqual(
            degraded.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testCreateAppendAndReloadCompleteMeeting() throws {
        let repository = try MeetingRepository.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let summaryDate = Date(timeIntervalSince1970: 1_100)
        let checkpointDate = Date(timeIntervalSince1970: 1_200)

        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: startedAt,
            title: "项目会议",
            audioManifestPath: "meetings/audio/manifest.json"
        )
        try repository.appendTranscript(
            meetingID: id,
            start: 0,
            end: 5,
            text: "项目开始",
            isFinal: true,
            sourceRevision: 2
        )
        try repository.appendBookmark(
            meetingID: id,
            timestamp: 4,
            createdAt: Date(timeIntervalSince1970: 1_004)
        )
        try repository.saveSummary(
            meetingID: id,
            overview: "确认启动计划",
            keyPoints: ["范围已确认"],
            decisions: ["今日启动"],
            actionItems: ["负责人准备排期"],
            bookmarkInsights: ["00:04 核心决定"],
            model: "deepseek-chat",
            createdAt: summaryDate
        )
        try repository.setNotionPage(
            meetingID: id,
            pageID: "page-id",
            pageURL: "https://www.notion.so/page-id"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: id,
            notionPageID: "page-id",
            nextSection: "transcript",
            nextBatchIndex: 2,
            updatedAt: checkpointDate
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.title, "项目会议")
        XCTAssertEqual(meeting.mode, .offline)
        XCTAssertEqual(meeting.state, .preparing)
        XCTAssertEqual(meeting.startedAt, startedAt)
        XCTAssertEqual(meeting.audioManifestPath, "meetings/audio/manifest.json")
        XCTAssertEqual(meeting.notionPageID, "page-id")
        XCTAssertEqual(meeting.notionPageURL, "https://www.notion.so/page-id")

        let transcript = try XCTUnwrap(meeting.transcripts.first)
        XCTAssertEqual(transcript.startTime, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.endTime, 5, accuracy: 0.001)
        XCTAssertEqual(transcript.text, "项目开始")
        XCTAssertTrue(transcript.isFinal)
        XCTAssertNil(transcript.speakerID)
        XCTAssertEqual(transcript.sourceRevision, 2)
        XCTAssertNil(transcript.sourceRawValue)
        XCTAssertEqual(transcript.source, .mixed)

        let bookmark = try XCTUnwrap(meeting.bookmarks.first)
        XCTAssertEqual(bookmark.timestamp, 4, accuracy: 0.001)

        let summary = try XCTUnwrap(meeting.summary)
        XCTAssertEqual(summary.overview, "确认启动计划")
        XCTAssertEqual(summary.keyPoints, ["范围已确认"])
        XCTAssertEqual(summary.decisions, ["今日启动"])
        XCTAssertEqual(summary.actionItems, ["负责人准备排期"])
        XCTAssertEqual(summary.bookmarkInsights, ["00:04 核心决定"])
        XCTAssertEqual(summary.model, "deepseek-chat")
        XCTAssertEqual(summary.createdAt, summaryDate)

        let checkpoint = try XCTUnwrap(meeting.archiveCheckpoint)
        XCTAssertEqual(checkpoint.notionPageID, "page-id")
        XCTAssertEqual(checkpoint.nextSection, "transcript")
        XCTAssertEqual(checkpoint.nextBatchIndex, 2)
        XCTAssertEqual(checkpoint.updatedAt, checkpointDate)
    }

    func testMeetingsPlaceMostRecentlyPinnedFirstThenSortUnpinnedByStartDate() throws {
        let repository = try MeetingRepository.inMemory()
        let oldestID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "最早会议"
        )
        let middleID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200),
            title: "中间会议"
        )
        let newestID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 300),
            title: "最新会议"
        )

        try repository.setPinned(
            meetingID: newestID,
            pinnedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.setPinned(
            meetingID: oldestID,
            pinnedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(
            try repository.meetings().map(\.id),
            [oldestID, newestID, middleID]
        )
        XCTAssertGreaterThan(
            try repository.meeting(id: oldestID).updatedAt,
            Date(timeIntervalSince1970: 100)
        )
    }

    func testClearingPinRestoresNormalMeetingOrder() throws {
        let repository = try MeetingRepository.inMemory()
        let olderID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newerID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        try repository.setPinned(
            meetingID: olderID,
            pinnedAt: Date(timeIntervalSince1970: 1_000)
        )

        try repository.setPinned(meetingID: olderID, pinnedAt: nil)

        XCTAssertEqual(try repository.meetings().map(\.id), [newerID, olderID])
        XCTAssertNil(try repository.meeting(id: olderID).pinnedAt)
        XCTAssertFalse(try repository.meeting(id: olderID).isPinned)
    }

    func testUpdatingTitlePersistsValueAndRefreshesUpdatedAt() throws {
        let repository = try MeetingRepository.inMemory()
        let startedAt = Date(timeIntervalSince1970: 100)
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: startedAt,
            title: "旧标题"
        )

        try repository.updateTitle(
            meetingID: meetingID,
            title: "新标题"
        )

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.title, "新标题")
        XCTAssertGreaterThan(meeting.updatedAt, startedAt)
    }

    func testUpdateTitleRestoresRealRecordWhenInjectedSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "旧标题"
        )
        let meeting = try repository.meeting(id: meetingID)
        let originalTitle = meeting.title
        let originalUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.updateTitle(
                meetingID: meetingID,
                title: "不应留在内存中"
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.title, originalTitle)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(saveAttempts, 2)
    }

    func testExistingInitializerAndNewRepositoryRecordsDefaultToUnpinned() throws {
        let existingStyleRecord = MeetingRecord(
            title: "旧记录",
            mode: .offline,
            state: .ready,
            startedAt: Date(timeIntervalSince1970: 50)
        )
        let repository = try MeetingRepository.inMemory()
        let newID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(existingStyleRecord.pinnedAt)
        XCTAssertFalse(existingStyleRecord.isPinned)
        XCTAssertNil(try repository.meeting(id: newID).pinnedAt)
        XCTAssertFalse(try repository.meeting(id: newID).isPinned)
    }

    func testMeetingOrderUsesUUIDAsFinalDeterministicTieBreaker() throws {
        let repository = try MeetingRepository.inMemory()
        let timestamp = Date(timeIntervalSince1970: 100)
        let firstID = try repository.createMeeting(
            mode: .offline,
            startedAt: timestamp
        )
        let secondID = try repository.createMeeting(
            mode: .online,
            startedAt: timestamp
        )

        let expected = [firstID, secondID].sorted {
            $0.uuidString < $1.uuidString
        }

        XCTAssertEqual(try repository.meetings().map(\.id), expected)
    }

    func testFinalizingMeetingPersistsReadyStateEndAndActiveDuration() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let endedAt = Date(timeIntervalSince1970: 145)

        try repository.finalizeMeeting(
            id: id,
            endedAt: endedAt,
            activeDuration: 31
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(meeting.endedAt, endedAt)
        XCTAssertEqual(meeting.activeDuration, 31, accuracy: 0.001)
        XCTAssertEqual(meeting.updatedAt, endedAt)
    }

    func testFinalizingMeetingAtomicallyPersistsSourceDegradation() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let endedAt = Date(timeIntervalSince1970: 145)

        try repository.finalizeMeeting(
            id: id,
            endedAt: endedAt,
            activeDuration: 31,
            sourceDegradationErrorCode:
                "source_track_write_failed_microphone"
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(meeting.endedAt, endedAt)
        XCTAssertEqual(meeting.activeDuration, 31, accuracy: 0.001)
        XCTAssertEqual(meeting.updatedAt, endedAt)
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testFinalizingRequestedMeetingCompletesSpeakerProcessingAndClearsError()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        try repository.markSpeakerProcessingStarted(meetingID: id)
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingErrorCode = "stale_progress_error"

        try repository.finalizeMeeting(
            id: id,
            endedAt: Date(timeIntervalSince1970: 145),
            activeDuration: 31
        )

        XCTAssertEqual(meeting.speakerProcessingState, .completed)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testFinalizingPreservesExistingSpeakerDegradationWithoutNewCode()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            "source_track_write_failed_microphone"
        try repository.updateMeetingState(id: id, state: .finalizing)

        try repository.finalizeMeeting(
            id: id,
            endedAt: Date(timeIntervalSince1970: 145),
            activeDuration: 31
        )

        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testCompletedSpeakerFieldsRollBackWhenFinalMeetingSaveFails()
        throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 3 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        try repository.markSpeakerProcessingStarted(meetingID: id)
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingErrorCode = "prior_safe_error"

        XCTAssertThrowsError(
            try repository.finalizeMeeting(
                id: id,
                endedAt: Date(timeIntervalSince1970: 145),
                activeDuration: 31
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        XCTAssertEqual(meeting.state, .preparing)
        XCTAssertNil(meeting.endedAt)
        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "prior_safe_error"
        )
        XCTAssertEqual(saveAttempts, 3)
    }

    func testAtomicFinalizationRestoresEveryFieldWhenSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: startedAt,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        let originalStateRawValue = meeting.stateRawValue
        let originalEndedAt = meeting.endedAt
        let originalActiveDuration = meeting.activeDuration
        let originalUpdatedAt = meeting.updatedAt
        let originalSpeakerStateRawValue =
            meeting.speakerProcessingStateRawValue
        let originalSpeakerErrorCode = meeting.speakerProcessingErrorCode

        XCTAssertThrowsError(
            try repository.finalizeMeeting(
                id: id,
                endedAt: Date(timeIntervalSince1970: 145),
                activeDuration: 31,
                sourceDegradationErrorCode:
                    "source_track_write_failed_microphone"
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: id)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.stateRawValue, originalStateRawValue)
        XCTAssertEqual(reloaded.endedAt, originalEndedAt)
        XCTAssertEqual(reloaded.activeDuration, originalActiveDuration)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(
            reloaded.speakerProcessingStateRawValue,
            originalSpeakerStateRawValue
        )
        XCTAssertEqual(
            reloaded.speakerProcessingErrorCode,
            originalSpeakerErrorCode
        )
        XCTAssertEqual(saveAttempts, 2)
    }

    func testDegradationAdapterRestoresUpdatedAtWhenSaveFails() async throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        let originalStateRawValue =
            meeting.speakerProcessingStateRawValue
        let originalErrorCode = meeting.speakerProcessingErrorCode
        let originalUpdatedAt = meeting.updatedAt
        let adapter = MeetingRepositoryLifecycleAdapter(
            repository: repository
        )

        do {
            try await adapter.markSpeakerProcessingDegraded(
                meetingID: id,
                errorCode: "source_track_write_failed_microphone"
            )
            XCTFail("Expected injected repository save failure")
        } catch {
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: id)
        XCTAssertEqual(
            reloaded.speakerProcessingStateRawValue,
            originalStateRawValue
        )
        XCTAssertEqual(reloaded.speakerProcessingErrorCode, originalErrorCode)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(saveAttempts, 2)
    }

    func testReplaceTranscriptsPersistsAttributedFinalRevision() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "临时转录"
        )

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 4,
                        endTime: 6,
                        text: "远端发言"
                    ),
                    speakerID: "remote",
                    source: .system
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 3,
                        text: "本地发言"
                    ),
                    speakerID: "me",
                    source: .microphone
                )
            ],
            sourceRevision: 7
        )

        let persistedMeeting = try repository.meeting(id: meetingID)
        let transcripts = persistedMeeting.transcripts.sorted {
            $0.startTime < $1.startTime
        }
        XCTAssertEqual(transcripts.count, 2)
        XCTAssertEqual(
            transcripts.map(\.text),
            ["本地发言", "远端发言"]
        )
        XCTAssertEqual(transcripts.map(\.speakerID), ["me", "remote"])
        XCTAssertEqual(transcripts.map(\.source), [.microphone, .system])
        XCTAssertEqual(transcripts.map(\.sourceRevision), [7, 7])
        XCTAssertTrue(transcripts.allSatisfy(\.isFinal))
        XCTAssertTrue(
            transcripts.allSatisfy { $0.meeting === persistedMeeting }
        )
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 2)
    }

    func testReplacementPersistsAssemblySequenceAcrossRepositoryReload() throws {
        var capturedContainer: ModelContainer?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContainer = context.container
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let assembled = SpeakerTranscriptAssembler().assemble([
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 5,
                    text: "first"
                ),
                speakerID: "remote",
                source: .system
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 3,
                    text: "second"
                ),
                speakerID: "me",
                source: .microphone
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 4,
                    text: "third"
                ),
                speakerID: "room-1",
                source: .room
            )
        ])

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: assembled,
            sourceRevision: 8
        )

        let sameRepositoryRecords = try repository.transcripts(
            meetingID: meetingID
        )
        XCTAssertEqual(
            sameRepositoryRecords.map(\.text),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            sameRepositoryRecords.map(\.sequenceIndex),
            [0, 1, 2]
        )

        let reloadedRepository = MeetingRepository(
            container: try XCTUnwrap(capturedContainer)
        )
        let reloadedRecords = try reloadedRepository.transcripts(
            meetingID: meetingID
        )
        XCTAssertEqual(
            reloadedRecords.map(\.text),
            ["first", "second", "third"]
        )
        XCTAssertEqual(reloadedRecords.map(\.sequenceIndex), [0, 1, 2])
    }

    func testReplacementReadSortsOutOfOrderDraftsChronologically() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 10,
                        endTime: 12,
                        text: "later"
                    ),
                    speakerID: "remote",
                    source: .system
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 2,
                        text: "earlier"
                    ),
                    speakerID: "me",
                    source: .microphone
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 5,
                        endTime: 6,
                        text: "middle"
                    ),
                    speakerID: "room-1",
                    source: .room
                )
            ],
            sourceRevision: 8
        )

        let records = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(records.map(\.text), ["earlier", "middle", "later"])
        XCTAssertEqual(records.map(\.sequenceIndex), [1, 2, 0])
    }

    func testTranscriptReadTotallyOrdersMixedSequenceRows() throws {
        var capturedContext: ModelContext?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContext = context
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let records = [
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                startTime: 1,
                endTime: 2,
                text: "same-legacy-long",
                isFinal: true,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                startTime: 1,
                endTime: 5,
                text: "same-indexed-one",
                isFinal: true,
                sequenceIndex: 1,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                startTime: 2,
                endTime: 3,
                text: "later-indexed-zero",
                isFinal: true,
                sequenceIndex: 0,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                startTime: 1,
                endTime: 6,
                text: "same-indexed-zero",
                isFinal: true,
                sequenceIndex: 0,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                startTime: 0,
                endTime: 1,
                text: "earliest-legacy",
                isFinal: true,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                startTime: 1,
                endTime: 1,
                text: "same-legacy-short",
                isFinal: true,
                meeting: meeting
            )
        ]
        let modelContext = try XCTUnwrap(capturedContext)
        records.forEach(modelContext.insert)
        meeting.transcripts = records
        try modelContext.save()

        let sortedRecords = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(
            sortedRecords.map(\.text),
            [
                "earliest-legacy",
                "same-indexed-zero",
                "same-indexed-one",
                "same-legacy-short",
                "same-legacy-long",
                "later-indexed-zero"
            ]
        )
    }

    func testLegacyTranscriptsWithoutSequenceFallBackToChronology() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 5,
            end: 6,
            text: "later"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1,
            end: 2,
            text: "earlier"
        )

        let records = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(records.map(\.text), ["earlier", "later"])
        XCTAssertTrue(records.allSatisfy { $0.sequenceIndex == nil })
    }

    func testReplaceTranscriptsRestoresExactPreviousStateWhenSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 4 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "旧转录一",
            isFinal: false,
            speakerID: "legacy-1",
            sourceRevision: 2
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 3,
            end: 5,
            text: "旧转录二",
            isFinal: true,
            speakerID: "legacy-2",
            sourceRevision: 3
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldTranscripts = meeting.transcripts
        let oldMetadata = oldTranscripts.map(TranscriptMetadata.init)
        let oldUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: [
                    AttributedTranscriptDraft(
                        transcript: TranscriptDraft(
                            startTime: 10,
                            endTime: 12,
                            text: "不应残留"
                        ),
                        speakerID: "remote",
                        source: .system
                    )
                ],
                sourceRevision: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.updatedAt, oldUpdatedAt)
        XCTAssertEqual(reloaded.transcripts.count, oldTranscripts.count)
        XCTAssertTrue(
            zip(reloaded.transcripts, oldTranscripts).allSatisfy(===)
        )
        XCTAssertEqual(
            reloaded.transcripts.map(TranscriptMetadata.init),
            oldMetadata
        )
        XCTAssertTrue(
            reloaded.transcripts.allSatisfy { $0.meeting === meeting }
        )
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 2)
        XCTAssertEqual(saveAttempts, 4)
    }

    func testReplaceTranscriptsFailurePreservesUnrelatedPendingInsertion() throws {
        var saveAttempts = 0
        var capturedContext: ModelContext?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContext = context
                saveAttempts += 1
                if saveAttempts == 3 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "目标会议"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "旧转录",
            speakerID: "legacy",
            sourceRevision: 2
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldTranscript = try XCTUnwrap(meeting.transcripts.first)
        let pendingMeetingID = UUID()
        let pendingMeeting = MeetingRecord(
            id: pendingMeetingID,
            title: "不相关的待保存会议",
            mode: .offline,
            state: .preparing,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        try XCTUnwrap(capturedContext).insert(pendingMeeting)

        XCTAssertThrowsError(
            try repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: [
                    AttributedTranscriptDraft(
                        transcript: TranscriptDraft(
                            startTime: 10,
                            endTime: 12,
                            text: "失败的新转录"
                        ),
                        speakerID: "remote",
                        source: .system
                    )
                ],
                sourceRevision: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        try repository.appendBookmark(
            meetingID: meetingID,
            timestamp: 1
        )

        let reloaded = try XCTUnwrap(
            repository.meetings().first { $0.id == meetingID }
        )
        XCTAssertNotNil(
            try repository.meetings().first {
                $0.id == pendingMeetingID
            }
        )
        XCTAssertEqual(reloaded.transcripts.count, 1)
        let restoredTranscript = try XCTUnwrap(
            reloaded.transcripts.first
        )
        XCTAssertTrue(restoredTranscript === oldTranscript)
        XCTAssertEqual(restoredTranscript.text, "旧转录")
        XCTAssertTrue(restoredTranscript.meeting === reloaded)
        XCTAssertEqual(try repository.count(MeetingRecord.self), 2)
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 1)
        XCTAssertEqual(saveAttempts, 4)
    }

    func testDeletingMeetingCascadesToAllRelatedRecords() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .online, startedAt: .now)
        try repository.appendTranscript(
            meetingID: id,
            start: 0,
            end: 1,
            text: "测试"
        )
        try repository.appendBookmark(meetingID: id, timestamp: 0.5)
        try repository.saveSummary(
            meetingID: id,
            overview: "摘要",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "deepseek-chat"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: id,
            notionPageID: "page-id",
            nextSection: "metadata",
            nextBatchIndex: 0
        )

        try repository.deleteMeeting(id: id)

        XCTAssertEqual(try repository.count(MeetingRecord.self), 0)
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 0)
        XCTAssertEqual(try repository.count(BookmarkRecord.self), 0)
        XCTAssertEqual(try repository.count(SummaryRecord.self), 0)
        XCTAssertEqual(try repository.count(ArchiveCheckpointRecord.self), 0)
        XCTAssertThrowsError(try repository.meeting(id: id)) { error in
            XCTAssertEqual(error as? MeetingRepositoryError, .meetingNotFound(id))
        }
    }

    func testMissingMeetingWritesFailWithoutCreatingOrphans() throws {
        let repository = try MeetingRepository.inMemory()
        let missingID = UUID()

        XCTAssertThrowsError(
            try repository.appendTranscript(
                meetingID: missingID,
                start: 0,
                end: 1,
                text: "不应保存"
            )
        ) { error in
            XCTAssertEqual(error as? MeetingRepositoryError, .meetingNotFound(missingID))
        }
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 0)
    }
}

private enum InjectedRepositorySaveError: Error, Equatable {
    case forced
}

private struct TranscriptMetadata: Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isFinal: Bool
    let speakerID: String?
    let sourceRevision: Int
    let sourceRawValue: String?
    let sequenceIndex: Int?

    init(_ transcript: TranscriptRecord) {
        id = transcript.id
        startTime = transcript.startTime
        endTime = transcript.endTime
        text = transcript.text
        isFinal = transcript.isFinal
        speakerID = transcript.speakerID
        sourceRevision = transcript.sourceRevision
        sourceRawValue = transcript.sourceRawValue
        sequenceIndex = transcript.sequenceIndex
    }
}
