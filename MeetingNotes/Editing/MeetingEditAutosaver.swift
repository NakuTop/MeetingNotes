import Foundation
import Observation

enum MeetingLocalSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(message: String)
}

@MainActor
@Observable
final class MeetingEditAutosaver {
    typealias Delay = @MainActor @Sendable (Duration) async throws -> Void

    private static let liveDelay: Duration = .milliseconds(350)
    private static let failureMessage = "无法自动保存本地修改，请稍后重试。"

    private let delay: Delay
    private var generation = UUID()
    private var pendingDelayTask: Task<Void, Never>?
    private var latestSave: (@MainActor () throws -> Void)?

    private(set) var state: MeetingLocalSaveState = .idle

    init(
        delay: @escaping Delay = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.delay = delay
    }

    func schedule(
        _ save: @escaping @MainActor () throws -> Void
    ) {
        let token = UUID()
        generation = token
        latestSave = save
        state = .idle
        pendingDelayTask?.cancel()

        let delay = self.delay
        pendingDelayTask = Task { [weak self] in
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
              let save = latestSave else {
            return
        }
        state = .saving
        do {
            try save()
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
