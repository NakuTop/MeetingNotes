import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingRecoveryServiceTests: XCTestCase {
    func testScanIncludesOnlyInterruptedMeetingsAndDescribesRecoverableData() async throws {
        let fixture = try makeFixture()
        let recordingID = try fixture.repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.repository.updateMeetingState(id: recordingID, state: .recording)
        try fixture.repository.appendTranscript(
            meetingID: recordingID,
            start: 0,
            end: 2,
            text: "已保存转录"
        )
        try fixture.repository.appendBookmark(meetingID: recordingID, timestamp: 1)
        try await fixture.fileStore.saveManifest(
            manifestWithCompleteAndIncompleteTail(),
            meetingID: recordingID
        )

        let pausedID = try fixture.repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        try fixture.repository.updateMeetingState(id: pausedID, state: .paused)

        let finalizingID = try fixture.repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 300)
        )
        try fixture.repository.updateMeetingState(id: finalizingID, state: .finalizing)
        try await fixture.fileStore.saveManifest(
            AudioSegmentManifest(segments: [completeSegment()]),
            meetingID: finalizingID
        )

        let readyID = try fixture.repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 400)
        )
        try fixture.repository.updateMeetingState(id: readyID, state: .ready)

        let archivedID = try fixture.repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 500)
        )
        try fixture.repository.updateMeetingState(id: archivedID, state: .archived)

        let candidates = try await fixture.service.scan()

        XCTAssertEqual(
            Set(candidates.map(\.meetingID)),
            Set([recordingID, pausedID, finalizingID])
        )
        let recording = try XCTUnwrap(
            candidates.first { $0.meetingID == recordingID }
        )
        XCTAssertEqual(recording.interruptedState, .recording)
        XCTAssertEqual(recording.completeSegmentCount, 1)
        XCTAssertEqual(recording.incompleteSegmentCount, 1)
        XCTAssertEqual(recording.transcriptCount, 1)
        XCTAssertEqual(recording.bookmarkCount, 1)

        let paused = try XCTUnwrap(candidates.first { $0.meetingID == pausedID })
        XCTAssertEqual(paused.completeSegmentCount, 0)
        XCTAssertEqual(paused.incompleteSegmentCount, 0)
    }

    func testRecoverDiscardsIncompleteTailAndPreservesMeetingContent() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try fixture.repository.updateMeetingState(id: meetingID, state: .recording)
        try fixture.repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "保留的转录"
        )
        try fixture.repository.appendBookmark(meetingID: meetingID, timestamp: 1)
        try await fixture.fileStore.saveManifest(
            manifestWithCompleteAndIncompleteTail(),
            meetingID: meetingID
        )

        try await fixture.service.recover(
            meetingID: meetingID,
            targetState: .finalizing
        )

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.state, .finalizing)
        XCTAssertEqual(meeting.transcripts.map(\.text), ["保留的转录"])
        XCTAssertEqual(meeting.bookmarks.map(\.timestamp), [1])
        let manifest = try await fixture.fileStore.loadManifest(meetingID: meetingID)
        XCTAssertEqual(manifest.segments, [completeSegment()])
        XCTAssertTrue(manifest.segments.allSatisfy(\.isComplete))
    }

    func testRecoveryMayResolveToReadyButNeverToAnActiveCaptureState() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.repository.createMeeting(
            mode: .online,
            startedAt: .now
        )
        try fixture.repository.updateMeetingState(id: meetingID, state: .paused)

        try await fixture.service.recover(meetingID: meetingID, targetState: .ready)
        XCTAssertEqual(try fixture.repository.meeting(id: meetingID).state, .ready)

        try fixture.repository.updateMeetingState(id: meetingID, state: .paused)
        do {
            try await fixture.service.recover(
                meetingID: meetingID,
                targetState: .recording
            )
            XCTFail("Expected active capture state to be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingRecoveryError,
                .invalidTargetState(.recording)
            )
        }
        XCTAssertEqual(try fixture.repository.meeting(id: meetingID).state, .paused)
    }

    private func makeFixture() throws -> RecoveryFixture {
        let repository = try MeetingRepository.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecoveryServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let fileStore = MeetingFileStore(rootURL: root)
        return RecoveryFixture(
            repository: repository,
            fileStore: fileStore,
            service: MeetingRecoveryService(
                repository: repository,
                fileStore: fileStore
            )
        )
    }

    private func manifestWithCompleteAndIncompleteTail() -> AudioSegmentManifest {
        AudioSegmentManifest(
            segments: [
                completeSegment(),
                .init(
                    fileName: "segment-0002.caf",
                    startTime: 1,
                    endTime: 1.5,
                    frameCount: 8_000,
                    isComplete: false
                )
            ]
        )
    }

    private func completeSegment() -> AudioSegmentManifest.Segment {
        .init(
            fileName: "segment-0001.caf",
            startTime: 0,
            endTime: 1,
            frameCount: 16_000,
            isComplete: true
        )
    }
}

private struct RecoveryFixture {
    let repository: MeetingRepository
    let fileStore: MeetingFileStore
    let service: MeetingRecoveryService
}
