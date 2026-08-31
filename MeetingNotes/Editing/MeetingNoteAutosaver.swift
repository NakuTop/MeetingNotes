import Foundation
import Observation

struct MeetingNoteSaveRequest: Equatable, Sendable {
    let meetingID: UUID
    let noteID: UUID
    let timestamp: TimeInterval
    let text: String
    let sequenceIndex: Int
}

@MainActor
@Observable
final class MeetingNoteAutosaver {
    typealias Delay = @MainActor @Sendable (Duration) async throws -> Void
    typealias Save = @MainActor (MeetingNoteSaveRequest) throws -> Void
    typealias DelayedTaskCompletion = @MainActor @Sendable () -> Void

    private struct PendingSave {
        let request: MeetingNoteSaveRequest
        let save: Save
    }

    private static let liveDelay: Duration = .milliseconds(350)
    private static let failureMessage = "无法自动保存本地笔记，请稍后重试。"

    private let delay: Delay
    private let onDelayedTaskCompletion: DelayedTaskCompletion
    private var generation = UUID()
    private var pendingDelayTask: Task<Void, Never>?
    private var latestSave: PendingSave?

    private(set) var state: MeetingLocalSaveState = .idle

    init(
        delay: @escaping Delay = { duration in
            try await Task.sleep(for: duration)
        },
        onDelayedTaskCompletion: @escaping DelayedTaskCompletion = {}
    ) {
        self.delay = delay
        self.onDelayedTaskCompletion = onDelayedTaskCompletion
    }

    func schedule(
        _ request: MeetingNoteSaveRequest,
        save: @escaping Save
    ) {
        let token = UUID()
        generation = token
        latestSave = PendingSave(request: request, save: save)
        state = .idle
        pendingDelayTask?.cancel()

        let delay = self.delay
        let onDelayedTaskCompletion = self.onDelayedTaskCompletion
        pendingDelayTask = Task { [weak self] in
            defer { onDelayedTaskCompletion() }
            guard !Task.isCancelled else { return }
            do {
                try await delay(Self.liveDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.saveIfCurrent(token: token)
        }
    }

    func flush() async {
        guard latestSave != nil else { return }
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
        let token = UUID()
        generation = token
        saveIfCurrent(token: token)
    }

    func retry() async {
        guard case .failed = state,
              latestSave != nil else {
            return
        }
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
        let token = UUID()
        generation = token
        saveIfCurrent(token: token)
    }

    func cancel() {
        generation = UUID()
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
        latestSave = nil
        state = .idle
    }

    private func saveIfCurrent(token: UUID) {
        guard token == generation,
              let pending = latestSave else {
            return
        }
        state = .saving
        do {
            try pending.save(pending.request)
            guard token == generation else { return }
            pendingDelayTask = nil
            latestSave = nil
            state = .saved
        } catch {
            guard token == generation else { return }
            pendingDelayTask = nil
            state = .failed(message: Self.failureMessage)
        }
    }
}
