import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class RecordingAnnotationViewModelTests: XCTestCase {
    func testEnterFlushesBeforeCollapsingEditor() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 10)
        let delay = RecordingAnnotationNoteDelay()
        let completion = RecordingAnnotationCompletionCounter()
        let context = makeFileStoreContext()
        defer { context.remove() }
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: context.store,
            screenshotCapture: ImmediateMeetingScreenshotCapture(),
            presentationStore: presentation,
            noteDelay: { duration in
                try await delay.suspend(for: duration)
            },
            onNoteDelayedTaskCompletion: {
                completion.signal()
            },
            monotonicTime: { 13 },
            idGenerator: { UUID(uuidString: "00000000-0000-0000-0000-000000000111")! },
            now: { Date(timeIntervalSince1970: 2) }
        )

        viewModel.beginNote()
        viewModel.updateNoteDraft("需要跟进合同")
        await delay.waitForCallCount(1)

        await viewModel.submitNote()

        XCTAssertFalse(viewModel.isNoteEditorPresented)
        XCTAssertEqual(viewModel.noteSaveState, .saved)
        let notes = try repository.notes(meetingID: meetingID)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "需要跟进合同")
        XCTAssertEqual(notes.first?.timestamp, 3)

        delay.release(call: 0)
        await completion.wait(for: 1)
        XCTAssertEqual(try repository.notes(meetingID: meetingID).count, 1)
    }

    func testScreenshotUsesMeetingAndTimestampCapturedAtClick() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 20)
        let clock = RecordingAnnotationClock(value: 24.25)
        let capture = ControlledMeetingScreenshotCapture()
        let context = makeFileStoreContext()
        defer { context.remove() }
        let screenshotID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000222"
        )!
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: context.store,
            screenshotCapture: capture,
            presentationStore: presentation,
            monotonicTime: { clock.value },
            idGenerator: { screenshotID },
            now: { Date(timeIntervalSince1970: 3) }
        )
        let task = Task { await viewModel.captureScreenshot() }
        await capture.waitUntilEntered()

        clock.value = 200
        await capture.release()
        await task.value

        let screenshots = try repository.screenshots(meetingID: meetingID)
        XCTAssertEqual(screenshots.count, 1)
        XCTAssertEqual(screenshots.first?.id, screenshotID)
        XCTAssertEqual(screenshots.first?.timestamp, 4.25)
        XCTAssertEqual(viewModel.screenshotState, .saved)
    }

    func testLateScreenshotFromOldMeetingCannotAttachToNewMeeting() async throws {
        let repository = try MeetingRepository.inMemory()
        let oldMeetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let newMeetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 2)
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: oldMeetingID, monotonicTime: 10)
        let capture = ControlledMeetingScreenshotCapture()
        let context = makeFileStoreContext()
        defer { context.remove() }
        let screenshotID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000333"
        )!
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: context.store,
            screenshotCapture: capture,
            presentationStore: presentation,
            monotonicTime: { 15 },
            idGenerator: { screenshotID }
        )
        let task = Task { await viewModel.captureScreenshot() }
        await capture.waitUntilEntered()

        await presentation.clear(meetingID: oldMeetingID)
        await presentation.start(meetingID: newMeetingID, monotonicTime: 30)
        await capture.release()
        await task.value

        XCTAssertTrue(try repository.screenshots(meetingID: oldMeetingID).isEmpty)
        XCTAssertTrue(try repository.screenshots(meetingID: newMeetingID).isEmpty)
        XCTAssertEqual(presentation.meetingID, newMeetingID)
        XCTAssertEqual(presentation.phase, .recording)
        let relativePath = "\(oldMeetingID.uuidString)/screenshots/\(screenshotID.uuidString).png"
        do {
            _ = try await context.store.resolveScreenshotURL(
                meetingID: oldMeetingID,
                relativePath: relativePath
            )
            XCTFail("Expected stale screenshot file cleanup")
        } catch {
            XCTAssertEqual(error as? MeetingFileStoreError, .screenshotNotFound)
        }
    }

    func testRepositoryFailureRollsBackSavedScreenshotFile() async throws {
        let failure = RecordingAnnotationPersistenceFailure()
        let repository = try MeetingRepository.inMemory { context in
            if failure.shouldFail {
                throw RecordingAnnotationTestError.forced
            }
            try context.save()
        }
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 10)
        let context = makeFileStoreContext()
        defer { context.remove() }
        let screenshotID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000444"
        )!
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: context.store,
            screenshotCapture: ImmediateMeetingScreenshotCapture(),
            presentationStore: presentation,
            monotonicTime: { 12 },
            idGenerator: { screenshotID }
        )
        failure.shouldFail = true

        await viewModel.captureScreenshot()

        XCTAssertTrue(try repository.screenshots(meetingID: meetingID).isEmpty)
        guard case .failed = viewModel.screenshotState else {
            return XCTFail("Expected nonfatal screenshot failure")
        }
        let relativePath = "\(meetingID.uuidString)/screenshots/\(screenshotID.uuidString).png"
        do {
            _ = try await context.store.resolveScreenshotURL(
                meetingID: meetingID,
                relativePath: relativePath
            )
            XCTFail("Expected failed metadata insertion to remove the PNG")
        } catch {
            XCTAssertEqual(error as? MeetingFileStoreError, .screenshotNotFound)
        }
    }

    func testPermissionFailureLeavesMeetingRecordingActive() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 10)
        let context = makeFileStoreContext()
        defer { context.remove() }
        let viewModel = RecordingAnnotationViewModel(
            repository: repository,
            fileStore: context.store,
            screenshotCapture: FailingMeetingScreenshotCapture(
                error: .screenRecordingDenied
            ),
            presentationStore: presentation,
            monotonicTime: { 15 }
        )

        await viewModel.captureScreenshot()

        XCTAssertEqual(viewModel.screenshotState, .permissionRequired)
        XCTAssertEqual(presentation.meetingID, meetingID)
        XCTAssertEqual(presentation.phase, .recording)
        XCTAssertEqual(presentation.activeDuration(for: meetingID, at: 16), 6)
        XCTAssertTrue(try repository.screenshots(meetingID: meetingID).isEmpty)
    }

    private func makeFileStoreContext() -> RecordingAnnotationFileStoreContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RecordingAnnotationViewModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        return RecordingAnnotationFileStoreContext(
            root: root,
            store: MeetingFileStore(rootURL: root)
        )
    }
}

private struct RecordingAnnotationFileStoreContext {
    let root: URL
    let store: MeetingFileStore

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class RecordingAnnotationClock {
    var value: TimeInterval

    init(value: TimeInterval) {
        self.value = value
    }
}

private actor ControlledMeetingScreenshotCapture: MeetingScreenshotCapturing {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return MeetingScreenshotCaptureResult(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            pixelWidth: 1440,
            pixelHeight: 900
        )
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct ImmediateMeetingScreenshotCapture: MeetingScreenshotCapturing {
    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        MeetingScreenshotCaptureResult(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            pixelWidth: 1280,
            pixelHeight: 720
        )
    }
}

private struct FailingMeetingScreenshotCapture: MeetingScreenshotCapturing {
    let error: MeetingScreenshotCaptureError

    func captureDisplayUnderMouse() async throws
        -> MeetingScreenshotCaptureResult {
        throw error
    }
}

@MainActor
private final class RecordingAnnotationPersistenceFailure {
    var shouldFail = false
}

private enum RecordingAnnotationTestError: Error {
    case forced
}

@MainActor
private final class RecordingAnnotationNoteDelay {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var callCountWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func suspend(for _: Duration) async throws {
        let call = callCount
        callCount += 1
        resumeSatisfiedWaiters()
        try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    func release(call: Int) {
        pending.removeValue(forKey: call)?.resume()
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callCountWaiters = remaining
    }
}

@MainActor
private final class RecordingAnnotationCompletionCounter {
    private var count = 0
    private var waiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func signal() {
        count += 1
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in waiters {
            if count >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}
