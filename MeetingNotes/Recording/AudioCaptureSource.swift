import Foundation

protocol AudioCaptureSource: Sendable {
    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error>
    func pause() async throws
    func resume() async throws
    func stop() async
}

enum AudioCaptureError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case invalidInputFormat
    case unableToCopyInputBuffer
    case engineStartFailed
}
