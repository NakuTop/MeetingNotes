import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

struct AudioOutputTestResult: Equatable, Sendable {
    let wasScheduled: Bool
    let duration: TimeInterval
    let outputDeviceID: AudioDeviceID?
}

enum AudioOutputTestError: Error, Equatable, LocalizedError {
    case selectedDeviceUnavailable(uid: String)
    case coreAudioFailure(status: OSStatus)
    case audioOutputUnitUnavailable
    case invalidToneParameters
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .selectedDeviceUnavailable:
            "所选输出设备当前不可用，请重新选择。"
        case .coreAudioFailure:
            "无法连接所选输出设备。"
        case .audioOutputUnitUnavailable:
            "无法启动音频输出测试。"
        case .invalidToneParameters:
            "测试音参数无效。"
        case .bufferCreationFailed:
            "无法生成测试音。"
        }
    }
}

protocol AudioOutputTesting: Sendable {
    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult
    func stop() async
}

protocol AudioOutputDeviceIDResolving: Sendable {
    func deviceID(forUID uid: String) async throws -> AudioDeviceID?
}

@MainActor
protocol AudioOutputToneDriving: Sendable {
    func playTone(
        outputDeviceID: AudioDeviceID?,
        duration: TimeInterval
    ) async throws -> Bool
    func stop()
}

struct CoreAudioOutputDeviceIDResolver: AudioOutputDeviceIDResolving {
    func deviceID(forUID uid: String) async throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputUID: CFString = uid as CFString
        var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        let response = withUnsafeMutablePointer(to: &inputUID) {
            inputPointer in
            withUnsafeMutablePointer(to: &outputDeviceID) {
                outputPointer in
                var translation = AudioValueTranslation(
                    mInputData: inputPointer,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: outputPointer,
                    mOutputDataSize: UInt32(
                        MemoryLayout<AudioDeviceID>.size
                    )
                )
                var dataSize = UInt32(
                    MemoryLayout<AudioValueTranslation>.size
                )
                let status = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    &translation
                )
                return (status, translation.mOutputDataSize)
            }
        }
        guard response.0 == noErr else {
            throw AudioOutputTestError.coreAudioFailure(
                status: response.0
            )
        }
        guard response.1 == UInt32(MemoryLayout<AudioDeviceID>.size),
              outputDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return outputDeviceID
    }
}

@MainActor
final class LiveAudioOutputTester: AudioOutputTesting {
    private static let maximumDuration: TimeInterval = 2

    private let preference: any AudioOutputDevicePreferenceReading
    private let resolver: any AudioOutputDeviceIDResolving
    private let driver: any AudioOutputToneDriving
    private var operationGeneration: UInt64 = 0

    init(
        preference: any AudioOutputDevicePreferenceReading,
        resolver: any AudioOutputDeviceIDResolving =
            CoreAudioOutputDeviceIDResolver(),
        driver: any AudioOutputToneDriving = LiveAudioOutputToneDriver()
    ) {
        self.preference = preference
        self.resolver = resolver
        self.driver = driver
    }

    func playTestTone(
        duration: TimeInterval
    ) async throws -> AudioOutputTestResult {
        operationGeneration &+= 1
        let requestedGeneration = operationGeneration

        return try await withTaskCancellationHandler {
            driver.stop()
            try ensureCurrent(requestedGeneration)

            let selectedUID = await preference.preferredOutputDeviceID()
            try ensureCurrent(requestedGeneration)

            let outputDeviceID: AudioDeviceID?
            if let selectedUID {
                let resolvedID = try await resolver.deviceID(
                    forUID: selectedUID
                )
                try ensureCurrent(requestedGeneration)
                guard let resolvedID else {
                    throw AudioOutputTestError.selectedDeviceUnavailable(
                        uid: selectedUID
                    )
                }
                outputDeviceID = resolvedID
            } else {
                outputDeviceID = nil
            }

            let requestedDuration = duration.isFinite ? duration : 0
            let cappedDuration = min(
                max(0, requestedDuration),
                Self.maximumDuration
            )
            try ensureCurrent(requestedGeneration)
            let wasScheduled = try await driver.playTone(
                outputDeviceID: outputDeviceID,
                duration: cappedDuration
            )
            try ensureCurrent(requestedGeneration)
            return AudioOutputTestResult(
                wasScheduled: wasScheduled,
                duration: cappedDuration,
                outputDeviceID: outputDeviceID
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelOperation(
                    ifCurrent: requestedGeneration
                )
            }
        }
    }

    func stop() async {
        operationGeneration &+= 1
        driver.stop()
    }

    private func ensureCurrent(_ requestedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard operationGeneration == requestedGeneration else {
            throw CancellationError()
        }
    }

    private func cancelOperation(ifCurrent requestedGeneration: UInt64) {
        guard operationGeneration == requestedGeneration else { return }
        operationGeneration &+= 1
        driver.stop()
    }
}

enum SineWavePCMBufferFactory {
    private static let maximumFrameCount: Double = 96_000

    static func makeBuffer(
        duration: TimeInterval,
        sampleRate: Double = 48_000,
        frequency: Double = 440,
        amplitude: Float = 0.08
    ) throws -> AVAudioPCMBuffer {
        guard duration.isFinite,
              duration > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              frequency.isFinite,
              frequency > 0,
              frequency < sampleRate / 2,
              amplitude.isFinite,
              amplitude > 0,
              amplitude <= 1 else {
            throw AudioOutputTestError.invalidToneParameters
        }
        let exactFrameCount = duration * sampleRate
        guard exactFrameCount.isFinite,
              exactFrameCount > 0,
              exactFrameCount <= Self.maximumFrameCount else {
            throw AudioOutputTestError.invalidToneParameters
        }
        let roundedFrameCount = exactFrameCount.rounded(.up)
        guard roundedFrameCount <= Double(AVAudioFrameCount.max) else {
            throw AudioOutputTestError.invalidToneParameters
        }
        let frameCount = AVAudioFrameCount(roundedFrameCount)
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ),
              let samples = buffer.floatChannelData?[0] else {
            throw AudioOutputTestError.bufferCreationFailed
        }

        buffer.frameLength = frameCount
        let boundedAmplitude = min(amplitude, 0.1)
        for index in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * frequency
                * Double(index) / sampleRate
            samples[index] = boundedAmplitude * Float(sin(phase))
        }
        return buffer
    }
}

@MainActor
protocol AudioOutputUnitDeviceRouting: Sendable {
    func route(
        outputUnit: AudioUnit,
        to deviceID: AudioDeviceID
    ) throws
}

@MainActor
struct CoreAudioOutputUnitDeviceRouter: AudioOutputUnitDeviceRouting {
    func route(
        outputUnit: AudioUnit,
        to deviceID: AudioDeviceID
    ) throws {
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioOutputTestError.coreAudioFailure(status: status)
        }
    }
}

@MainActor
protocol AudioOutputToneSession: AnyObject, Sendable {
    func play(
        buffer: AVAudioPCMBuffer,
        outputDeviceID: AudioDeviceID?
    ) async throws -> Bool
    func stop()
}

@MainActor
protocol AudioOutputToneSessionCreating: Sendable {
    func makeSession() -> any AudioOutputToneSession
}

@MainActor
protocol AudioOutputToneEngineControlling: AnyObject, Sendable {
    var outputUnit: AudioUnit? { get }

    func configure(format: AVAudioFormat)
    func prepare()
    func start() throws
    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @MainActor @Sendable () -> Void
    )
    func play()
    func stopAndReset()
}

@MainActor
final class LiveAudioOutputToneEngineController:
    AudioOutputToneEngineControlling {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    ) {
        self.engine = engine
        self.playerNode = playerNode
        engine.attach(playerNode)
    }

    var outputUnit: AudioUnit? {
        engine.outputNode.audioUnit
    }

    func configure(format: AVAudioFormat) {
        engine.connect(
            playerNode,
            to: engine.mainMixerNode,
            format: format
        )
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { _ in
            Task { @MainActor in
                completion()
            }
        }
    }

    func play() {
        playerNode.play()
    }

    func stopAndReset() {
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }
}

@MainActor
struct LiveAudioOutputToneSessionFactory:
    AudioOutputToneSessionCreating {
    private let router: any AudioOutputUnitDeviceRouting

    init(
        router: any AudioOutputUnitDeviceRouting =
            CoreAudioOutputUnitDeviceRouter()
    ) {
        self.router = router
    }

    func makeSession() -> any AudioOutputToneSession {
        LiveAudioOutputToneSession(
            controller: LiveAudioOutputToneEngineController(),
            router: router
        )
    }
}

@MainActor
final class LiveAudioOutputToneDriver: AudioOutputToneDriving {
    private static let maximumDuration: TimeInterval = 2

    private let sessionFactory: any AudioOutputToneSessionCreating
    private var activeSession: (any AudioOutputToneSession)?

    init(
        sessionFactory: any AudioOutputToneSessionCreating =
            LiveAudioOutputToneSessionFactory()
    ) {
        self.sessionFactory = sessionFactory
    }

    func playTone(
        outputDeviceID: AudioDeviceID?,
        duration: TimeInterval
    ) async throws -> Bool {
        stop()
        try Task.checkCancellation()

        let requestedDuration = duration.isFinite ? duration : 0
        let buffer = try SineWavePCMBufferFactory.makeBuffer(
            duration: min(
                max(0, requestedDuration),
                Self.maximumDuration
            )
        )
        let session = sessionFactory.makeSession()
        activeSession = session
        defer {
            if activeSession === session {
                session.stop()
                activeSession = nil
            }
        }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.play(
                buffer: buffer,
                outputDeviceID: outputDeviceID
            )
        } onCancel: {
            Task { @MainActor in
                session.stop()
            }
        }
    }

    func stop() {
        activeSession?.stop()
        activeSession = nil
    }
}

@MainActor
final class LiveAudioOutputToneSession: AudioOutputToneSession {
    private struct ActivePlayback {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Error>
    }

    private let controller: any AudioOutputToneEngineControlling
    private let router: any AudioOutputUnitDeviceRouting
    private var activePlayback: ActivePlayback?

    init(
        controller: any AudioOutputToneEngineControlling =
            LiveAudioOutputToneEngineController(),
        router: any AudioOutputUnitDeviceRouting =
            CoreAudioOutputUnitDeviceRouter()
    ) {
        self.controller = controller
        self.router = router
    }

    func play(
        buffer: AVAudioPCMBuffer,
        outputDeviceID: AudioDeviceID?
    ) async throws -> Bool {
        try Task.checkCancellation()
        if activePlayback != nil {
            stopActivePlayback(
                resumingWith: .failure(CancellationError())
            )
        }

        do {
            if let outputDeviceID {
                guard let outputUnit = controller.outputUnit else {
                    throw AudioOutputTestError.audioOutputUnitUnavailable
                }
                try router.route(
                    outputUnit: outputUnit,
                    to: outputDeviceID
                )
            }

            controller.configure(format: buffer.format)
            controller.prepare()
            try controller.start()
            try Task.checkCancellation()
        } catch {
            controller.stopAndReset()
            throw error
        }

        let playbackID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activePlayback = ActivePlayback(
                    id: playbackID,
                    continuation: continuation
                )
                guard !Task.isCancelled else {
                    stopActivePlayback(
                        resumingWith: .failure(CancellationError())
                    )
                    return
                }
                controller.schedule(buffer: buffer) { [weak self] in
                    self?.complete(playbackID: playbackID)
                }
                guard activePlayback?.id == playbackID else { return }
                guard !Task.isCancelled else {
                    stopActivePlayback(
                        resumingWith: .failure(CancellationError())
                    )
                    return
                }
                controller.play()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(playbackID: playbackID)
            }
        }
    }

    func stop() {
        stopActivePlayback(resumingWith: .failure(CancellationError()))
    }

    private func complete(playbackID: UUID) {
        guard activePlayback?.id == playbackID else { return }
        stopActivePlayback(resumingWith: .success(true))
    }

    private func cancel(playbackID: UUID) {
        guard activePlayback?.id == playbackID else { return }
        stopActivePlayback(resumingWith: .failure(CancellationError()))
    }

    private func stopActivePlayback(
        resumingWith result: Result<Bool, Error>
    ) {
        guard let playback = activePlayback else { return }
        activePlayback = nil
        controller.stopAndReset()
        playback.continuation.resume(with: result)
    }
}
