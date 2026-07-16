import Foundation
import Observation

@MainActor
protocol MeetingLibraryRepository: AnyObject {
    func meetings() throws -> [MeetingRecord]
    func setPinned(meetingID: UUID, pinnedAt: Date?) throws
    func deleteMeeting(id: UUID) throws
}

extension MeetingRepository: MeetingLibraryRepository {}

protocol MeetingFileDeleting: Actor {
    func deleteMeetingDirectory(for meetingID: UUID) async throws
}

extension MeetingFileStore: MeetingFileDeleting {}

protocol MeetingStarting: Sendable {
    @discardableResult
    func start(mode: MeetingMode) async throws -> UUID
}

extension MeetingCoordinator: MeetingStarting {}

@MainActor
@Observable
final class MeetingLibraryViewModel {
    private struct ErrorPresentation: Equatable {
        var message: String?
        var repairPermissions: [CapturePermission] = []
        var failedStartMode: MeetingMode?
    }

    private let repository: any MeetingLibraryRepository
    private let fileDeleter: any MeetingFileDeleting
    private let starter: any MeetingStarting
    private let titleUpdater: any MeetingTitleUpdating
    private let operationGate: MeetingOperationGate
    private let playbackStopper: any MeetingPlaybackStopping
    private let systemRequirements: any SystemRequirementChecking
    private let recordingsURL: URL

    private(set) var meetings: [MeetingRecord] = []
    var selectedMeetingID: UUID?
    private(set) var isStarting = false
    private(set) var deletingMeetingIDs: Set<UUID> = []
    private(set) var pinningMeetingIDs: Set<UUID> = []
    private(set) var renamingMeetingIDs: Set<UUID> = []
    private var errorPresentation = ErrorPresentation()
    private(set) var systemRequirementsSnapshot: SystemRequirementsSnapshot

    var errorMessage: String? { errorPresentation.message }
    var permissionRepairPermissions: [CapturePermission] {
        errorPresentation.repairPermissions
    }
    var lastFailedStartMode: MeetingMode? {
        errorPresentation.failedStartMode
    }

    init(
        repository: any MeetingLibraryRepository,
        fileDeleter: any MeetingFileDeleting,
        starter: any MeetingStarting,
        titleUpdater: any MeetingTitleUpdating,
        operationGate: MeetingOperationGate,
        playbackStopper: any MeetingPlaybackStopping,
        systemRequirements: any SystemRequirementChecking = SystemRequirements(),
        recordingsURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.repository = repository
        self.fileDeleter = fileDeleter
        self.starter = starter
        self.titleUpdater = titleUpdater
        self.operationGate = operationGate
        self.playbackStopper = playbackStopper
        self.systemRequirements = systemRequirements
        self.recordingsURL = recordingsURL
        systemRequirementsSnapshot = systemRequirements.snapshot(
            for: recordingsURL
        )
    }

    var selectedMeeting: MeetingRecord? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    func load() {
        refreshSystemRequirements()
        do {
            meetings = try repository.meetings()
            if let selectedMeetingID,
               !meetings.contains(where: { $0.id == selectedMeetingID }) {
                self.selectedMeetingID = nil
            }
            setErrorPresentation()
        } catch {
            setErrorPresentation(message: "无法加载会议记录，请重试。")
        }
    }

    func select(_ meetingID: UUID?) {
        selectedMeetingID = meetingID
    }

    func returnHome() {
        selectedMeetingID = nil
    }

    func togglePinned(id: UUID, at date: Date = .now) {
        guard !pinningMeetingIDs.contains(id) else { return }
        guard let meeting = meetingForOperation(id: id) else {
            setErrorPresentation(message: "找不到要置顶的会议，请刷新后重试。")
            return
        }
        let targetDate: Date? = meeting.isPinned ? nil : date
        pinningMeetingIDs.insert(id)
        setErrorPresentation()
        defer { pinningMeetingIDs.remove(id) }

        do {
            try repository.setPinned(meetingID: id, pinnedAt: targetDate)
            load()
        } catch {
            setErrorPresentation(
                message: targetDate == nil
                    ? "无法取消置顶会议，请重试。"
                    : "无法置顶会议，请重试。"
            )
        }
    }

    func renameMeeting(id: UUID, title: String) async -> Bool {
        guard !renamingMeetingIDs.contains(id) else { return false }
        guard let meeting = meetingForOperation(id: id) else {
            setErrorPresentation(message: "找不到要重命名的会议，请刷新后重试。")
            return false
        }
        guard canRename(meeting) else {
            setErrorPresentation(
                message: MeetingTitleUpdateError
                    .invalidState(meeting.state)
                    .userMessage
            )
            return false
        }
        renamingMeetingIDs.insert(id)
        setErrorPresentation()
        defer { renamingMeetingIDs.remove(id) }

        do {
            try await titleUpdater.updateTitle(meetingID: id, title: title)
            load()
            return true
        } catch is CancellationError {
            return false
        } catch let error as MeetingTitleUpdateError {
            setErrorPresentation(message: error.userMessage)
            return false
        } catch {
            setErrorPresentation(message: "无法重命名会议，请稍后重试。")
            return false
        }
    }

    func startMeeting(mode: MeetingMode) async {
        guard !isStarting else { return }
        setErrorPresentation()
        refreshSystemRequirements()
        guard systemRequirementsSnapshot.isSupportedPlatform else {
            setErrorPresentation(
                message: "仅支持 macOS 15 或更高版本的 Apple Silicon Mac。"
            )
            return
        }
        guard systemRequirementsSnapshot.hasEnoughDiskSpace else {
            setErrorPresentation(
                message: "可用磁盘空间不足 2 GB，无法安全开始录音。"
            )
            return
        }
        isStarting = true
        defer { isStarting = false }

        do {
            let createdMeetingID = try await starter.start(mode: mode)
            load()
            selectedMeetingID = createdMeetingID
        } catch {
            let message = Self.message(for: error, operation: .start)
            if case let MeetingCoordinatorError.permissionDenied(permissions) =
                error {
                setErrorPresentation(
                    message: message,
                    repairPermissions: permissions.sorted {
                        Self.permissionRank($0) < Self.permissionRank($1)
                    },
                    failedStartMode: mode
                )
            } else {
                setErrorPresentation(message: message)
            }
        }
    }

    func retryLastStart() async {
        guard !isStarting, let mode = lastFailedStartMode else { return }
        setErrorPresentation()
        await startMeeting(mode: mode)
    }

    func deleteMeeting(id: UUID) async {
        guard !deletingMeetingIDs.contains(id) else { return }
        guard let meeting = meetingForOperation(id: id) else {
            setErrorPresentation(message: "找不到要删除的会议，请刷新后重试。")
            return
        }
        guard canDelete(meeting) else {
            setErrorPresentation(message: "会议正在录制或处理中，暂时不能删除。")
            return
        }
        guard operationGate.acquire(.delete, for: id) else {
            setErrorPresentation(message: "会议正在执行其他操作，暂时不能删除。")
            return
        }
        defer { operationGate.release(.delete, for: id) }
        deletingMeetingIDs.insert(id)
        setErrorPresentation()
        defer { deletingMeetingIDs.remove(id) }

        playbackStopper.stop(meetingID: id)
        do {
            try await fileDeleter.deleteMeetingDirectory(for: id)
            try repository.deleteMeeting(id: id)
            if selectedMeetingID == id {
                selectedMeetingID = nil
            }
            load()
        } catch {
            setErrorPresentation(
                message: Self.message(for: error, operation: .delete)
            )
        }
    }

    func canSummarize(meetingIn state: RecordingState) -> Bool {
        state == .ready
    }

    func canDelete(_ meeting: MeetingRecord) -> Bool {
        switch meeting.state {
        case .idle, .ready, .summaryReady, .archived:
            true
        case .preparing, .recording, .paused, .finalizing,
                .summarizing, .archiving:
            false
        }
    }

    func canRename(_ meeting: MeetingRecord) -> Bool {
        switch meeting.state {
        case .summarizing, .archiving:
            false
        case .idle, .preparing, .recording, .paused, .finalizing,
                .ready, .summaryReady, .archived:
            true
        }
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
        setErrorPresentation()
    }

    func reportControlFailure(_ error: Error) {
        setErrorPresentation(
            message: Self.message(for: error, operation: .control)
        )
    }

    func refreshSystemRequirements() {
        systemRequirementsSnapshot = systemRequirements.snapshot(
            for: recordingsURL
        )
    }

    private func meetingForOperation(id: UUID) -> MeetingRecord? {
        meetings.first(where: { $0.id == id })
            ?? (try? repository.meetings().first { $0.id == id })
    }

    private func setErrorPresentation(
        message: String? = nil,
        repairPermissions: [CapturePermission] = [],
        failedStartMode: MeetingMode? = nil
    ) {
        errorPresentation = ErrorPresentation(
            message: message,
            repairPermissions: repairPermissions,
            failedStartMode: failedStartMode
        )
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
            let names = permissions.sorted {
                permissionRank($0) < permissionRank($1)
            }.map {
                switch $0 {
                case .microphone: "麦克风"
                case .screenRecording: "屏幕与系统音频录制"
                }
            }.joined(separator: "、")
            let relaunchHint = permissions.contains(.screenRecording)
                ? "屏幕录制权限更改后，macOS 可能要求完全退出并重新打开 App。"
                : ""
            return "缺少\(names)权限，请在系统设置中允许后重试。\(relaunchHint)"
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

    private static func permissionRank(_ permission: CapturePermission) -> Int {
        switch permission {
        case .microphone: 0
        case .screenRecording: 1
        }
    }
}
