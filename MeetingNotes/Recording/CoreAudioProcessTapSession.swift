import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case processLookupFailed(OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case inputFailed
    case inputFailure(CoreAudioMicrophoneError)

    static func preservingStage(of error: Error) -> Self {
        if let error = error as? Self { return error }
        if let error = error as? CoreAudioMicrophoneError { return .inputFailure(error) }
        return .inputFailed
    }

    // Local-only, allowlisted stage + numeric status. Never include raw error
    // descriptions, process/device identifiers or paths in the presentation.
    var localMessage: String {
        if self == .permissionDenied {
            return "系统音频访问被拒绝。请在系统设置的“屏幕与系统音频录制”中允许本 App 录制系统音频后重试，无需共享桌面。"
        }
        let detail: String
        switch self {
        case let .processLookupFailed(status): detail = "查询音频进程，错误 \(status)"
        case let .tapCreationFailed(status): detail = "创建纯音频捕获，错误 \(status)"
        case let .aggregateCreationFailed(status): detail = "配置纯音频输入，错误 \(status)"
        case let .inputFailure(error):
            switch error {
            case let .renderFailed(status): detail = "音频渲染，错误 \(status)"
            case let .initializationFailed(status): detail = "初始化音频输入，错误 \(status)"
            case let .startFailed(status): detail = "启动音频输入，错误 \(status)"
            case let .enableIOFailed(status): detail = "配置音频通道，错误 \(status)"
            case let .currentDeviceFailed(status): detail = "连接音频输入，错误 \(status)"
            case let .streamFormatReadFailed(status), let .streamFormatFailed(status):
                detail = "配置音频格式，错误 \(status)"
            case let .maximumFramesPerSliceFailed(status): detail = "读取缓冲区容量，错误 \(status)"
            case let .inputCallbackFailed(status): detail = "配置音频回调，错误 \(status)"
            case .unitCreationFailed: detail = "创建音频单元"
            case .invalidDeviceFormat, .invalidFormat: detail = "音频格式不可用"
            case .bufferAllocationFailed: detail = "分配音频缓冲区"
            case .deviceUnavailable, .defaultDeviceUnavailable: detail = "音频输入不可用"
            case .notConfigured: detail = "音频输入未配置"
            }
        case .inputFailed: detail = "读取音频输入"
        case .permissionDenied: detail = "访问被拒绝"
        }
        return "系统音频采集失败（\(detail)）。请在设置中运行“智能诊断”检查 Core Audio 纯音频链路。"
    }
}

protocol SystemAudioCaptureSession: Sendable {
    func start(onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) async throws
    func stop() async
}

enum SystemAudioCaptureEvent: Sendable {
    case frame(CapturedAudioFrame)
    case failure(Error)
}

protocol CoreAudioProcessTapAPI: Sendable {
    func currentProcessObjectID() throws -> AudioObjectID
    func createTap(description: CATapDescription) throws -> AudioObjectID
    func createAggregate(tapUID: String) throws -> AudioObjectID
    func destroyAggregate(_ id: AudioObjectID)
    func destroyTap(_ id: AudioObjectID)
}

enum SystemAudioTapPolicy {
    private static let aggregateUIDPrefix = "com.shenminghao.MeetingNotes.system-audio-tap."

    static func isOwnedAggregateUID(_ uid: String) -> Bool {
        guard uid.hasPrefix(aggregateUIDPrefix) else { return false }
        return UUID(uuidString: String(uid.dropFirst(aggregateUIDPrefix.count))) != nil
    }

    static func description(excluding process: AudioObjectID?) -> CATapDescription {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: process.map { [$0] } ?? [])
        description.name = "MeetingNotes System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    static func aggregateDescription(tapUID: String, id: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "MeetingNotes System Audio Input",
            kAudioAggregateDeviceUIDKey: aggregateUIDPrefix + id.uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Do not wait for another application to start playing before
            // returning from capture startup (silence is a valid input).
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
    }
}

struct LiveCoreAudioProcessTapAPI: CoreAudioProcessTapAPI {
    func currentProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.processLookupFailed(status)
        }
        return object
    }

    func createTap(description: CATapDescription) throws -> AudioObjectID {
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.tapCreationFailed(status)
        }
        return tap
    }

    func createAggregate(tapUID: String) throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        let description = SystemAudioTapPolicy.aggregateDescription(tapUID: tapUID, id: UUID())
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw SystemAudioCaptureError.aggregateCreationFailed(status)
        }
        return device
    }

    func destroyAggregate(_ id: AudioObjectID) { AudioHardwareDestroyAggregateDevice(id) }
    func destroyTap(_ id: AudioObjectID) { AudioHardwareDestroyProcessTap(id) }
}

actor CoreAudioProcessTapSession: SystemAudioCaptureSession {
    private let excludesCurrentProcessAudio: Bool
    private let api: any CoreAudioProcessTapAPI
    private let readerFactory: @Sendable () -> any CoreAudioMicrophoneSessionManaging
    private var activeRun: CoreAudioProcessTapRun?

    init(excludesCurrentProcessAudio: Bool = true,
         api: any CoreAudioProcessTapAPI = LiveCoreAudioProcessTapAPI(),
         readerFactory: @escaping @Sendable () -> any CoreAudioMicrophoneSessionManaging = {
             LiveCoreAudioMicrophoneSession()
         }) {
        self.api = api
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.readerFactory = readerFactory
    }

    deinit { activeRun?.requestStop() }

    func start(onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard activeRun == nil else { throw AudioCaptureError.alreadyRunning }
        // Only the explicitly invoked diagnostic includes the app's own test
        // tone. Meeting capture always keeps the default self-exclusion.
        let process = excludesCurrentProcessAudio ? try api.currentProcessObjectID() : nil
        let description = SystemAudioTapPolicy.description(excluding: process)
        let tap = try api.createTap(description: description)
        let aggregate: AudioObjectID
        do {
            aggregate = try api.createAggregate(tapUID: description.uuid.uuidString)
        } catch {
            api.destroyTap(tap)
            throw error
        }
        let run = CoreAudioProcessTapRun(
            api: api, tap: tap, aggregate: aggregate,
            reader: readerFactory(), onEvent: onEvent
        )
        activeRun = run
        do {
            try await withTaskCancellationHandler {
                try await run.start()
                try Task.checkCancellation()
                guard activeRun === run, !run.isStopping else { throw CancellationError() }
            } onCancel: {
                run.requestStop()
            }
        } catch {
            if activeRun === run { activeRun = nil }
            run.requestStop()
            // A cancelled caller must not wait for a non-cooperative HAL
            // startup. The run keeps its own resources until that call exits.
            if !(error is CancellationError) { await run.waitUntilClosed() }
            throw error
        }
    }

    func stop() async {
        guard let run = activeRun else { return }
        activeRun = nil
        let wasStarted = run.startupHasFinished
        run.requestStop()
        if wasStarted { await run.waitUntilClosed() }
    }
}

// Each attempt owns a distinct reader/tap/aggregate. The lock only protects
// control state, never runs on the AUHAL real-time callback. Results are
// retained before continuation registration; all resumes occur outside it.
private final class CoreAudioProcessTapRun: @unchecked Sendable {
    private let lock = NSLock()
    private let api: any CoreAudioProcessTapAPI
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let reader: any CoreAudioMicrophoneSessionManaging
    private let events: SystemAudioPCMEventRelay
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var worker: Task<Void, Never>?
    private var stopping = false
    private var startupFinished = false
    private var cleanupStarted = false
    private var closed = false
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []

    init(api: any CoreAudioProcessTapAPI, tap: AudioObjectID, aggregate: AudioObjectID,
         reader: any CoreAudioMicrophoneSessionManaging,
         onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) {
        self.api = api; self.tap = tap; self.aggregate = aggregate; self.reader = reader
        events = SystemAudioPCMEventRelay(onEvent: onEvent)
    }

    var isStopping: Bool { lock.withLock { stopping } }
    var startupHasFinished: Bool { lock.withLock { startupFinished } }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let prior = lock.withLock { () -> Result<Void, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let prior { continuation.resume(with: prior) }
            // Even a pre-registration cancel needs this worker to establish
            // startup completion and safely retire its locally owned handles.
            let task = Task { [self] in
                do {
                    try checkCurrent()
                    try await reader.configure(deviceID: aggregate) { [events] in events.receive($0) }
                    try checkCurrent()
                    try await reader.start()
                    try checkCurrent()
                    complete(.success(()))
                } catch {
                    let mapped: Error = error is CancellationError
                        ? CancellationError()
                        : SystemAudioCaptureError.preservingStage(of: error)
                    complete(.failure(mapped))
                    requestStop()
                }
                lock.withLock { startupFinished = true; worker = nil }
                beginCleanupIfReady()
            }
            let reject = lock.withLock {
                if !startupFinished { worker = task }
                return stopping
            }
            if reject { task.cancel() }
        }
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        if isStopping { throw CancellationError() }
    }

    private func complete(_ terminal: Result<Void, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = terminal
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: terminal)
    }

    func requestStop() {
        let task = lock.withLock { stopping = true; return worker }
        events.close()
        complete(.failure(CancellationError()))
        task?.cancel()
        beginCleanupIfReady()
    }

    private func beginCleanupIfReady() {
        let shouldClose = lock.withLock {
            guard stopping, startupFinished, !cleanupStarted else { return false }
            cleanupStarted = true
            return true
        }
        guard shouldClose else { return }
        Task { [self] in
            // No tap/aggregate teardown can race a still-in-flight configure
            // or start. AUHAL stop also drains its non-RT delivery queue.
            await reader.stop()
            api.destroyAggregate(aggregate)
            api.destroyTap(tap)
            let waiters = lock.withLock {
                closed = true
                let waiters = closedWaiters
                closedWaiters = []
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let alreadyClosed = lock.withLock {
                if closed { return true }
                closedWaiters.append(continuation)
                return false
            }
            if alreadyClosed { continuation.resume() }
        }
    }
}

private final class SystemAudioPCMEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private let onEvent: @Sendable (SystemAudioCaptureEvent) -> Void
    private let converter = PCMConverter(outputSampleRate: 48_000, amplitudePolicy: .preserveAmplitude)

    init(onEvent: @escaping @Sendable (SystemAudioCaptureEvent) -> Void) { self.onEvent = onEvent }
    func close() { lock.withLock { accepting = false } }

    func receive(_ event: CoreAudioMicrophoneSessionEvent) {
        guard lock.withLock({ accepting }) else { return }
        let output: SystemAudioCaptureEvent
        switch event {
        case let .buffer(buffer, sampleTime, sampleRate):
            do {
                guard sampleRate.isFinite, sampleRate > 0 else { throw SystemAudioCaptureError.inputFailed }
                output = .frame(try converter.convert(buffer, timestamp: Double(sampleTime) / sampleRate))
            } catch { output = .failure(SystemAudioCaptureError.inputFailed) }
        case let .failure(error):
            output = .failure(SystemAudioCaptureError.preservingStage(of: error))
        }
        if lock.withLock({ accepting }) { onEvent(output) }
    }
}
