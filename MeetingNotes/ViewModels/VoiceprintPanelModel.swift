import Foundation
import Observation

struct VoiceprintSelection: Sendable {
    let meetingID: UUID
    let start: Double
    let end: Double
    let canEnroll: Bool
    var canMatch = true
}

@MainActor @Observable
final class VoiceprintPanelModel: Identifiable {
    let id = UUID()
    let selection: VoiceprintSelection?
    private let library: LocalVoiceprintLibrary
    private let reader: VoiceprintClipReader
    private let settings: AppSettingsStore
    private let onConfirmName: @MainActor (String) -> Bool
    @ObservationIgnored private(set) var operation: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private static var configurationRevision: UInt64 = 0
    private var token = UUID()
    var enrollmentName = ""
    var enrollmentConsent = false
    private(set) var profiles: [VoiceprintProfileSummary] = []
    private(set) var suggestion: VoiceprintSuggestion?
    private(set) var isWorking = false
    private(set) var message: String?
    var enabled: Bool { settings.localVoiceprintsEnabled }

    init(library: LocalVoiceprintLibrary, reader: VoiceprintClipReader, settings: AppSettingsStore,
         selection: VoiceprintSelection?, onConfirmName: @escaping @MainActor (String) -> Bool) {
        self.library = library
        self.reader = reader
        self.settings = settings
        self.selection = selection
        self.onConfirmName = onConfirmName
    }

    func load() {
        run { try await self.library.summaries() } apply: { self.profiles = $0 }
    }

    func setEnabled(_ value: Bool) {
        cancel()
        settings.localVoiceprintsEnabled = value
        Self.configurationRevision += 1
        let revision = Self.configurationRevision
        let library = library
        // A bounded state update survives closing the sheet. Monotonic requests
        // prevent rapid toggles (including another window) arriving out of order.
        configurationTask = Task {
            await library.setEnabled(value, request: revision)
        }
        message = value ? "仅在本机处理；匹配结果必须由你确认。" : "已停用声纹匹配。已录入的声纹仍可删除。"
    }

    func enroll() {
        guard enabled, enrollmentConsent, selection?.canEnroll == true else { return }
        let name = enrollmentName
        run {
            let samples = try await self.selectedSamples()
            try await self.library.enroll(name: name, samples: samples, consent: true)
            try Task.checkCancellation()
            return try await self.library.summaries()
        } apply: { profiles in
            self.profiles = profiles
            self.enrollmentConsent = false
            self.enrollmentName = ""
            self.message = "声纹已加密保存在本机；未修改任何转录姓名。"
        }
    }

    func match() {
        guard enabled, selection?.canMatch == true else { return }
        run {
            let samples = try await self.selectedSamples()
            return try await self.library.suggest(samples: samples)
        } apply: { suggestion in
            self.suggestion = suggestion
            self.message = suggestion == nil ? "没有足够明确的匹配；未更改任何说话人。" : nil
        }
    }

    func confirmSuggestion() {
        guard let suggestion else { return }
        run {
            try await self.library.confirmedName(for: suggestion)
        } apply: { name in
            self.message = self.onConfirmName(name)
                ? "已由你确认，将姓名应用到所选这一段。"
                : Self.message(for: SpeakerAssignmentError.staleTranscript)
        }
    }

    func delete(_ profile: VoiceprintProfileSummary) {
        cancel()
        run {
            try await self.library.delete(id: profile.id)
            return try await self.library.summaries()
        } apply: { profiles in
            self.profiles = profiles
            self.message = "已删除本机声纹。已有转录姓名不变。"
        }
    }

    func deleteAll() {
        cancel()
        run {
            try await self.library.deleteAll()
        } apply: { _ in
            self.profiles = []
            self.message = "已删除全部本机声纹。会议录音和已有转录姓名未删除。"
        }
    }

    func cancel() {
        token = UUID()
        operation?.cancel()
        operation = nil
        isWorking = false
        suggestion = nil
    }

    private func selectedSamples() async throws -> [Float] {
        guard let selection else { throw VoiceprintError.poorAudio }
        return try await reader.samples(meetingID: selection.meetingID, start: selection.start, end: selection.end)
    }

    private func run<Value: Sendable>(
        _ body: @escaping @MainActor () async throws -> Value,
        apply: @escaping @MainActor (Value) -> Void
    ) {
        guard operation == nil else { return }
        let current = UUID()
        token = current
        isWorking = true
        message = nil
        suggestion = nil
        let configurationTask = configurationTask
        operation = Task { [weak self] in
            do {
                await configurationTask?.value
                try Task.checkCancellation()
                let value = try await body()
                try Task.checkCancellation()
                guard let self, self.token == current else { return }
                // Every UI mutation after suspension is applied under this
                // generation check, not inside the asynchronous worker body.
                apply(value)
            } catch is CancellationError {
                // No stale UI/error or persisted enrollment after cancellation.
            } catch {
                guard let self, self.token == current else { return }
                self.message = Self.message(for: error)
            }
            guard let self, self.token == current else { return }
            self.isWorking = false
            self.operation = nil
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case VoiceprintError.disabled: "声纹库尚未启用。"
        case VoiceprintError.consentRequired: "请先确认已获得该发言人的同意。"
        case VoiceprintError.invalidName: "请输入 1 到 40 个字符的姓名。"
        case VoiceprintError.multipleSpeakers: "这段可能包含多位发言人，请选择清晰的单人发言。"
        case VoiceprintError.poorAudio: "请选择至少 5 秒、音量正常且无重叠的单人发言；最多使用前 20 秒。"
        case VoiceprintError.staleOperation: "声纹库或开关已更改，请重新操作。"
        case VoiceprintError.libraryFull: "本机最多保存 64 条声纹，请先删除不需要的条目。"
        case VoiceprintError.duplicateName: "此姓名已有声纹。要重新录入，请先删除旧条目；未覆盖已有声纹。"
        case SpeakerAssignmentError.staleTranscript: "转录已更新，请重新选择要标注的段落。"
        default: "无法完成本地声纹操作；原录音、转录及已有声纹未被替换。请重试或检查本机模型。"
        }
    }
}
