import AVFoundation
import Foundation

struct MicrophoneSample: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sampleTime: AVAudioFramePosition
    let sampleRate: Double
    let timestamp: TimeInterval?

    init(
        buffer: AVAudioPCMBuffer,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double,
        timestamp: TimeInterval? = nil
    ) {
        self.buffer = buffer
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}

protocol MicrophoneSampleProviding: Sendable {
    func start(
        deviceID: String?
    ) async throws -> AsyncThrowingStream<MicrophoneSample, Error>
    func pause() async throws
    func resume() async throws
    func stop() async
}
