import AVFoundation
import FluidAudio
import Foundation

actor FluidAudioSpeakerDiarizer: SpeakerDiarizing {
    private static let sampleRate = 16_000
    private static let bufferFrameCount: AVAudioFrameCount = 16_384

    private let modelsDirectory: URL
    nonisolated(unsafe) private let manager: OfflineDiarizerManager
    private var modelsArePrepared = false

    init(
        modelsDirectory: URL,
        manager: OfflineDiarizerManager = OfflineDiarizerManager()
    ) {
        self.modelsDirectory = modelsDirectory
        self.manager = manager
    }

    func diarize(
        source: MeetingAudioSource
    ) async throws -> [SpeakerInterval] {
        try await prepareModelsIfNeeded()

        let audioURL: URL
        let shouldDeleteAudioURL: Bool
        do {
            (audioURL, shouldDeleteAudioURL) =
                try makeContinuousAudioURL(for: source)
        } catch {
            throw SpeakerDiarizationError.inferenceFailed
        }
        defer {
            if shouldDeleteAudioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        do {
            let factory = StreamingAudioSourceFactory()
            let (audioSource, loadDuration) =
                try factory.makeDiskBackedSource(
                    from: audioURL,
                    targetSampleRate: Self.sampleRate
                )
            defer { audioSource.cleanup() }

            let result = try await manager.process(
                audioSource: audioSource,
                audioLoadingSeconds: loadDuration
            )
            return result.segments.map {
                SpeakerInterval(
                    rawSpeakerID: $0.speakerId,
                    startTime: TimeInterval($0.startTimeSeconds),
                    endTime: TimeInterval($0.endTimeSeconds)
                )
            }
        } catch {
            throw SpeakerDiarizationError.inferenceFailed
        }
    }

    private func prepareModelsIfNeeded() async throws {
        guard !modelsArePrepared else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory,
                withIntermediateDirectories: true
            )
            try await manager.prepareModels(directory: modelsDirectory)
            modelsArePrepared = true
        } catch {
            throw SpeakerDiarizationError.modelPreparationFailed
        }
    }

    private func makeContinuousAudioURL(
        for source: MeetingAudioSource
    ) throws -> (url: URL, shouldDelete: Bool) {
        guard let firstURL = source.segmentURLs.first else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        guard source.segmentURLs.count > 1 else {
            return (firstURL, false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meeting-notes-diarization-\(UUID().uuidString).caf"
            )
        do {
            let firstFile = try AVAudioFile(forReading: firstURL)
            let format = firstFile.processingFormat
            firstFile.close()

            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            defer { outputFile.close() }

            for segmentURL in source.segmentURLs {
                try append(
                    segmentURL: segmentURL,
                    expectedFormat: format,
                    to: outputFile
                )
            }
            return (outputURL, true)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func append(
        segmentURL: URL,
        expectedFormat: AVAudioFormat,
        to outputFile: AVAudioFile
    ) throws {
        let inputFile = try AVAudioFile(forReading: segmentURL)
        defer { inputFile.close() }

        let inputFormat = inputFile.processingFormat
        guard inputFormat.sampleRate == expectedFormat.sampleRate,
              inputFormat.channelCount == expectedFormat.channelCount,
              inputFormat.commonFormat == expectedFormat.commonFormat else {
            throw SpeakerDiarizationError.inferenceFailed
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: expectedFormat,
            frameCapacity: Self.bufferFrameCount
        ) else {
            throw SpeakerDiarizationError.inferenceFailed
        }

        while inputFile.framePosition < inputFile.length {
            let remaining = inputFile.length - inputFile.framePosition
            let frameCount = AVAudioFrameCount(
                min(Int64(Self.bufferFrameCount), remaining)
            )
            try inputFile.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else {
                throw SpeakerDiarizationError.inferenceFailed
            }
            try outputFile.write(from: buffer)
        }
    }
}
