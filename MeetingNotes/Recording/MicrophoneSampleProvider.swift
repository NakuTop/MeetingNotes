import AVFoundation
import Foundation

struct MicrophoneSample: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sampleTime: AVAudioFramePosition
    let sampleRate: Double

    init(
        buffer: AVAudioPCMBuffer,
        sampleTime: AVAudioFramePosition,
        sampleRate: Double
    ) {
        self.buffer = buffer
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
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
