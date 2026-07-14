import Foundation
import Observation

@MainActor
protocol MeetingLibraryRepository: AnyObject {
    func meetings() throws -> [MeetingRecord]
    func deleteMeeting(id: UUID) throws
}

extension MeetingRepository: MeetingLibraryRepository {}

protocol MeetingFileDeleting: Actor {
    func deleteMeetingDirectory(for meetingID: UUID) throws
}

extension MeetingFileStore: MeetingFileDeleting {}

protocol MeetingStarting: Sendable {
    func start(mode: MeetingMode) async throws
}

extension MeetingCoordinator: MeetingStarting {}

@MainActor
@Observable
final class MeetingLibraryViewModel {
    private let repository: any MeetingLibraryRepository
    private let fileDeleter: any MeetingFileDeleting
    private let starter: any MeetingStarting

    private(set) var meetings: [MeetingRecord] = []
    var selectedMeetingID: UUID?
    private(set) var isStarting = false
    private(set) var deletingMeetingIDs: Set<UUID> = []
    private(set) var errorMessage: String?

    init(
        repository: any MeetingLibraryRepository,
        fileDeleter: any MeetingFileDeleting,
        starter: any MeetingStarting
    ) {
        self.repository = repository
        self.fileDeleter = fileDeleter
        self.starter = starter
    }

    var selectedMeeting: MeetingRecord? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    func load() {
        do {
            meetings = try repository.meetings().sorted {
                $0.startedAt > $1.startedAt
            }
            if let selectedMeetingID,
               !meetings.contains(where: { $0.id == selectedMeetingID }) {
                self.selectedMeetingID = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = "无法加载会议记录，请重试。"
        }
    }

    func select(_ meetingID: UUID?) {
        selectedMeetingID = meetingID
    }

    func startMeeting(mode: MeetingMode) async {
        guard !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        do {
            try await starter.start(mode: mode)
            load()
            selectedMeetingID = meetings.first?.id
        } catch {
            errorMessage = Self.message(for: error, operation: .start)
        }
    }

    func deleteMeeting(id: UUID) async {
        guard !deletingMeetingIDs.contains(id) else { return }
        deletingMeetingIDs.insert(id)
        errorMessage = nil
        defer { deletingMeetingIDs.remove(id) }

        do {
            try await fileDeleter.deleteMeetingDirectory(for: id)
            try repository.deleteMeeting(id: id)
            if selectedMeetingID == id {
                selectedMeetingID = nil
            }
            load()
        } catch {
            errorMessage = Self.message(for: error, operation: .delete)
        }
    }

    func canSummarize(meetingIn state: RecordingState) -> Bool {
        state == .ready
    }

    func shouldHighlightTranscript(
        start: TimeInterval,
        end: TimeInterval,
        bookmarkTimes: [TimeInterval]
    ) -> Bool {
        bookmarkTimes.contains {
            BookmarkWindow(bookmarkTime: $0).intersects(
                transcriptStart: start,
                transcriptEnd: end
            )
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportControlFailure(_ error: Error) {
        errorMessage = Self.message(for: error, operation: .control)
    }

    private enum Operation {
        case start
        case delete
        case control
    }

    private static func message(
        for error: Error,
        operation: Operation
    ) -> String {
        if case let MeetingCoordinatorError.permissionDenied(permissions) = error {
            let names = permissions.map {
                switch $0 {
                case .microphone: "麦克风"
                case .screenRecording: "屏幕与系统音频录制"
                }
            }.sorted().joined(separator: "、")
            return "缺少\(names)权限，请在系统设置中允许后重试。"
        }

        switch operation {
        case .start:
            return "无法开始会议，请检查权限和音频设备后重试。"
        case .delete:
            return "无法完整删除会议，请重试。"
        case .control:
            return "录音操作未完成，请返回主窗口重试。"
        }
    }
}
