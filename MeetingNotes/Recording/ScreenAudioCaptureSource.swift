import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenAudioCaptureError: Error, Equatable, Sendable {
    case screenRecordingDenied
    case noDisplayAvailable
    case streamSetupFailed
    case streamStartFailed
    case streamStopped
    case invalidAudioSample
}

enum ScreenAudioCaptureConfiguration {
    static let registeredOutputTypes: [SCStreamOutputType] = [
        .audio,
        .microphone
    ]

    static func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(RealtimeAudioMixer.sampleRate)
        configuration.channelCount = 1
        return configuration
    }
}

actor ScreenAudioCaptureSource: AudioCaptureSource {
    private let mixer: RealtimeAudioMixer
    private let decoder: ScreenAudioSampleDecoder
    private let systemQueue = DispatchQueue(
        label: "MeetingNotes.ScreenAudio.System",
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: "MeetingNotes.ScreenAudio.Microphone",
        qos: .userInitiated
    )
    private var stream: SCStream?
    private var relay: ScreenAudioStreamRelay?
    private var continuation: AsyncThrowingStream<CapturedAudioFrame, Error>.Continuation?
    private var isPaused = false
    private var outputTimestampOrigin: TimeInterval?

    init(
        mixer: RealtimeAudioMixer = RealtimeAudioMixer(),
        decoder: ScreenAudioSampleDecoder = ScreenAudioSampleDecoder()
    ) {
        self.mixer = mixer
        self.decoder = decoder
    }

    func start() async throws -> AsyncThrowingStream<CapturedAudioFrame, Error> {
        guard stream == nil else {
            throw AudioCaptureError.alreadyRunning
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw ScreenAudioCaptureError.screenRecordingDenied
            }
            throw ScreenAudioCaptureError.streamSetupFailed
        }
        guard let display = content.displays.first else {
            throw ScreenAudioCaptureError.noDisplayAvailable
        }
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = ScreenAudioCaptureConfiguration.makeStreamConfiguration()
        let streamPair = AsyncThrowingStream<CapturedAudioFrame, Error>.makeStream()
        continuation = streamPair.continuation
        isPaused = false
        outputTimestampOrigin = nil

        let source = self
        let relay = ScreenAudioStreamRelay(
            decoder: decoder,
            frameHandler: { frame, audioSource in
                Task {
                    await source.consume(frame, source: audioSource)
                }
            },
            failureHandler: {
                Task {
                    await source.handleStreamFailure()
                }
            }
        )
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: relay
        )

        do {
            for outputType in ScreenAudioCaptureConfiguration.registeredOutputTypes {
                try stream.addStreamOutput(
                    relay,
                    type: outputType,
                    sampleHandlerQueue: queue(for: outputType)
                )
            }
        } catch {
            removeRegisteredOutputs(from: stream, relay: relay)
            continuation?.finish(throwing: ScreenAudioCaptureError.streamSetupFailed)
            continuation = nil
            throw ScreenAudioCaptureError.streamSetupFailed
        }

        self.stream = stream
        self.relay = relay
        do {
            try await stream.startCapture()
        } catch {
            removeRegisteredOutputs(from: stream, relay: relay)
            self.stream = nil
            self.relay = nil
            continuation?.finish(throwing: ScreenAudioCaptureError.streamStartFailed)
            continuation = nil
            throw ScreenAudioCaptureError.streamStartFailed
        }
        return streamPair.stream
    }

    func pause() async throws {
        guard stream != nil else {
            throw AudioCaptureError.notRunning
        }
        isPaused = true
        for frame in await mixer.flush() {
            continuation?.yield(normalizeOutputTimestamp(frame))
        }
    }

    func resume() async throws {
        guard stream != nil else {
            throw AudioCaptureError.notRunning
        }
        isPaused = false
    }

    func stop() async {
        guard let stream, let relay else {
            return
        }
        try? await stream.stopCapture()
        removeRegisteredOutputs(from: stream, relay: relay)
        for frame in await mixer.flush() {
            continuation?.yield(normalizeOutputTimestamp(frame))
        }
        continuation?.finish()
        continuation = nil
        self.stream = nil
        self.relay = nil
        isPaused = false
        outputTimestampOrigin = nil
    }

    private func queue(for outputType: SCStreamOutputType) -> DispatchQueue {
        outputType == .microphone ? microphoneQueue : systemQueue
    }

    private func removeRegisteredOutputs(
        from stream: SCStream,
        relay: ScreenAudioStreamRelay
    ) {
        for outputType in ScreenAudioCaptureConfiguration.registeredOutputTypes {
            try? stream.removeStreamOutput(relay, type: outputType)
        }
    }

    private func consume(
        _ frame: CapturedAudioFrame,
        source: RealtimeAudioSource
    ) async {
        guard stream != nil, !isPaused else {
            return
        }
        do {
            let frames = try await mixer.ingest(frame, source: source)
            for frame in frames {
                continuation?.yield(normalizeOutputTimestamp(frame))
            }
        } catch {
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    private func normalizeOutputTimestamp(
        _ frame: CapturedAudioFrame
    ) -> CapturedAudioFrame {
        if outputTimestampOrigin == nil {
            outputTimestampOrigin = frame.timestamp
        }
        let origin = outputTimestampOrigin ?? frame.timestamp
        return CapturedAudioFrame(
            timestamp: max(0, frame.timestamp - origin),
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            samples: frame.samples
        )
    }

    private func handleStreamFailure() {
        guard stream != nil else {
            return
        }
        continuation?.finish(throwing: ScreenAudioCaptureError.streamStopped)
        continuation = nil
        stream = nil
        relay = nil
        isPaused = false
        outputTimestampOrigin = nil
    }
}

final class ScreenAudioSampleDecoder: @unchecked Sendable {
    private let converter: PCMConverter

    init(converter: PCMConverter = PCMConverter()) {
        self.converter = converter
    }

    func decode(_ sampleBuffer: CMSampleBuffer) throws -> CapturedAudioFrame {
        guard sampleBuffer.isValid else {
            throw ScreenAudioCaptureError.invalidAudioSample
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(presentationTime)
        guard timestamp.isFinite else {
            throw ScreenAudioCaptureError.invalidAudioSample
        }

        let converted = try sampleBuffer.withAudioBufferList {
            audioBufferList,
            _ -> CapturedAudioFrame? in
            guard let description = sampleBuffer.formatDescription?
                .audioStreamBasicDescription,
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame
                ),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else {
                return nil
            }
            return try? converter.convert(buffer, timestamp: timestamp)
        }
        guard let converted else {
            throw ScreenAudioCaptureError.invalidAudioSample
        }
        return converted
    }
}

private final class ScreenAudioStreamRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let decoder: ScreenAudioSampleDecoder
    private let frameHandler: @Sendable (CapturedAudioFrame, RealtimeAudioSource) -> Void
    private let failureHandler: @Sendable () -> Void

    init(
        decoder: ScreenAudioSampleDecoder,
        frameHandler: @escaping @Sendable (
            CapturedAudioFrame,
            RealtimeAudioSource
        ) -> Void,
        failureHandler: @escaping @Sendable () -> Void
    ) {
        self.decoder = decoder
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        _ = stream
        let source: RealtimeAudioSource
        switch outputType {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }
        guard let frame = try? decoder.decode(sampleBuffer) else {
            return
        }
        frameHandler(frame, source)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        _ = stream
        _ = error
        failureHandler()
    }
}
